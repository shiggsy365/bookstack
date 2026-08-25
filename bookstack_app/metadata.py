import json
import re
from urllib.parse import urljoin

from .cache import cached_load
from .config import GOOGLE_BOOKS_API_KEY
from .discovery import (
    GOOGLE_BOOKS_BASE_URL, GOOGLE_BOOKS_ORIGINS, OPENLIBRARY_BASE_URL,
    OPENLIBRARY_ORIGINS, get_cached_json, openlibrary_headers
)
from .matching import normalize_title, title_words
from .providers import metadata_fields, normalize_google_book, normalize_openlibrary_book

METADATA_CACHE_SECONDS = 30 * 24 * 60 * 60
EMPTY_METADATA_CACHE_SECONDS = 6 * 60 * 60


def metadata_match_score(query_title, result_title):
    query, result = normalize_title(query_title), normalize_title(result_title)
    if not query or not result:
        return 0
    if query == result:
        return 100
    if query in result or result in query:
        return 80
    query_words, result_words = title_words(query), title_words(result)
    return int((len(query_words & result_words) / max(len(query_words), len(result_words))) * 100)


def clean_isbn(isbn):
    return re.sub(r'[^0-9Xx]', '', isbn or '')


def google_books_metadata(title, author='', isbn=''):
    terms = [f'isbn:{clean_isbn(isbn)}'] if clean_isbn(isbn) else [f'intitle:{title}']
    if author:
        terms.append(f'inauthor:{author}')
    params = {'q': ' '.join(terms), 'maxResults': 5, 'printType': 'books'}
    if GOOGLE_BOOKS_API_KEY:
        params['key'] = GOOGLE_BOOKS_API_KEY
    data = get_cached_json(
        f'googlebooks:metadata:{params["q"]}', urljoin(GOOGLE_BOOKS_BASE_URL, '/books/v1/volumes'),
        GOOGLE_BOOKS_ORIGINS, headers={'User-Agent': 'Bookstack Kindle Browser'},
        params=params, cache_seconds=METADATA_CACHE_SECONDS
    )
    best, best_score = {}, 0
    for item in data.get('items', []):
        normalized = normalize_google_book(item)
        score = metadata_match_score(title, normalized['title'])
        if score > best_score:
            best = metadata_fields(normalized)
            best_score = score
    return best if best_score >= 70 else {}


def openlibrary_metadata(title, author='', isbn=''):
    query = f'isbn:{clean_isbn(isbn)}' if clean_isbn(isbn) else f'title:"{title}"'
    if author:
        query += f' author:"{author}"'
    data = get_cached_json(
        f'openlibrary:metadata:{query}', urljoin(OPENLIBRARY_BASE_URL, '/search.json'),
        OPENLIBRARY_ORIGINS, headers=openlibrary_headers(),
        params={'q': query, 'fields': 'title,author_name,isbn,cover_i,first_publish_year', 'limit': 5},
        cache_seconds=METADATA_CACHE_SECONDS
    )
    best, best_score = {}, 0
    for item in data.get('docs', []):
        normalized = normalize_openlibrary_book(item)
        score = metadata_match_score(title, normalized['title'])
        if score > best_score:
            best = metadata_fields(normalized)
            best_score = score
    return best if best_score >= 70 else {}


def resolve_metadata(title, author='', isbn='', allow_google=False):
    cache_parts = (normalize_title(title), normalize_title(author), clean_isbn(isbn), bool(allow_google))
    cache_key = json.dumps(cache_parts, separators=(',', ':'))

    def load():
        metadata = {}
        try:
            metadata = openlibrary_metadata(title, author, isbn)
            if not metadata and author:
                metadata = openlibrary_metadata(title, '', isbn)
        except Exception:
            print('[Metadata] Open Library lookup failed', flush=True)
        if allow_google and (not metadata or not metadata.get('description')):
            try:
                fallback = google_books_metadata(title, author, isbn)
                if not fallback and author:
                    fallback = google_books_metadata(title, '', isbn)
                if fallback:
                    fallback.update({key: value for key, value in metadata.items() if value})
                    metadata = fallback
            except Exception:
                print('[Metadata] Google Books lookup failed', flush=True)
        return metadata

    return cached_load(
        f'metadata:{cache_key}', 'metadata',
        lambda data: METADATA_CACHE_SECONDS if data else EMPTY_METADATA_CACHE_SECONDS, load,
        stale_ttl=lambda data: METADATA_CACHE_SECONDS if data else EMPTY_METADATA_CACHE_SECONDS,
        lock_seconds=35
    )
