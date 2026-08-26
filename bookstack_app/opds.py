import base64
import re
from concurrent.futures import ThreadPoolExecutor, as_completed
import time
import xml.etree.ElementTree as ET
from urllib.parse import quote_plus, urljoin

import requests
from flask import Blueprint, jsonify, request

from .cache import cached_load
from .config import GRIMMORY_PASS, GRIMMORY_URL, GRIMMORY_USER, SHELFMARK_URL
from .discovery import OPENLIBRARY_BASE_URL, OPENLIBRARY_ORIGINS, get_cached_json, openlibrary_headers, openlibrary_work_description
from .matching import normalize_title, title_words
from .metadata import resolve_metadata
from .providers import clean_html
from .security import get_origin, get_with_allowed_redirects, validate_url

bp = Blueprint('opds', __name__, url_prefix='/api/opds')

NAMESPACES = {
    'atom': 'http://www.w3.org/2005/Atom',
    'dc': 'http://purl.org/dc/elements/1.1/',
    'opds': 'http://opds-spec.org/2010/catalog',
    'dcterms': 'http://purl.org/dc/terms/',
    'schema': 'http://schema.org/'
}
GRIMMORY_ORIGINS = {get_origin(GRIMMORY_URL)}
IMAGE_PROXY_ORIGINS = GRIMMORY_ORIGINS | {get_origin(SHELFMARK_URL)}
LIBRARY_SEARCH_CACHE_SECONDS = 5 * 60
LIBRARY_SEARCH_CACHE = {}


def grimmory_headers():
    auth_str = f'{GRIMMORY_USER}:{GRIMMORY_PASS}'
    encoded_auth = base64.b64encode(auth_str.encode('ascii')).decode('ascii')
    return {
        'User-Agent': 'Mozilla/5.0 (Kobo) AppleWebkit/537.36',
        'Authorization': f'Basic {encoded_auth}'
    }


def parse_opds_feed(xml_content, base_url):
    root, entries = ET.fromstring(xml_content), []
    for entry in root.findall('atom:entry', NAMESPACES):
        title_elem, id_elem = entry.find('atom:title', NAMESPACES), entry.find('atom:id', NAMESPACES)
        title_text = title_elem.text if title_elem is not None else 'Unknown Title'
        if title_text in ('Libraries', 'Shelves', 'Magic Shelves'):
            continue
        obj = {'title': title_text, 'id': id_elem.text if id_elem is not None else '', 'links': [],
               'series_name': None, 'series_index': None, 'description': '', 'isbn': ''}
        for identifier in entry.findall('dc:identifier', NAMESPACES) + entry.findall('dcterms:identifier', NAMESPACES):
            isbn_match = re.search(r'(97[89]\d{10}|\d{9}[\dXx])', identifier.text or '')
            if isbn_match:
                obj['isbn'] = isbn_match.group(1)
                break
        series_id = None
        for meta in entry.findall('atom:meta', NAMESPACES):
            prop = meta.get('property')
            if prop == 'belongs-to-collection':
                obj['series_name'], series_id = meta.text, meta.get('id')
            elif prop == 'group-position' and series_id and meta.get('refines') == f'#{series_id}':
                obj['series_index'] = meta.text
        if not obj['series_name']:
            series_elem = entry.find('schema:Series', NAMESPACES)
            if series_elem is not None:
                obj['series_name'], obj['series_index'] = series_elem.get('name'), series_elem.get('position')
        summary_elem, content_elem = entry.find('atom:summary', NAMESPACES), entry.find('atom:content', NAMESPACES)
        raw_desc = (summary_elem.text or '') if summary_elem is not None else ((content_elem.text or '') if content_elem is not None else '')
        obj['description'] = clean_html(raw_desc)
        author = entry.find('atom:author/atom:name', NAMESPACES)
        if author is not None:
            obj['author'] = author.text
        for link in entry.findall('atom:link', NAMESPACES):
            raw_href, rel = link.get('href'), link.get('rel') or ''
            if raw_href and raw_href.startswith('/') and ('image' in rel or 'thumbnail' in rel):
                href = f'/api/opds/image-proxy?url={quote_plus(raw_href)}'
            elif raw_href:
                href = raw_href if raw_href.startswith('http') else urljoin(base_url, raw_href)
            else:
                href = ''
            obj['links'].append({'href': href, 'rel': rel, 'type': link.get('type')})
        entries.append(obj)
    return {'entries': entries}


def get_cached_grimmory_entries(query):
    query = (query or '').strip()

    def load():
        search_url = f'{GRIMMORY_URL}/catalog?q={quote_plus(query)}'
        resp = get_with_allowed_redirects(
            search_url, allowed_origins=GRIMMORY_ORIGINS, headers=grimmory_headers(), timeout=20
        )
        resp.raise_for_status()
        return parse_opds_feed(resp.content, search_url)['entries']

    return cached_load(
        f'grimmory:search:{normalize_title(query)}', 'grimmory',
        LIBRARY_SEARCH_CACHE_SECONDS, load, stale_ttl=24 * 60 * 60, lock_seconds=25
    )


def get_library_catalogue():
    def load():
        entries = []
        for page in range(1, 101):
            url = f'{GRIMMORY_URL}/catalog?page={page}&size=100'
            resp = get_with_allowed_redirects(
                url, allowed_origins=GRIMMORY_ORIGINS, headers=grimmory_headers(), timeout=20
            )
            resp.raise_for_status()
            page_entries = parse_opds_feed(resp.content, url)['entries']
            entries.extend(page_entries)
            if len(page_entries) < 100:
                break
        return entries

    return cached_load(
        'grimmory:catalogue:v1', 'grimmory', LIBRARY_SEARCH_CACHE_SECONDS, load,
        stale_ttl=24 * 60 * 60, lock_seconds=60
    )


def title_match_score(book_title, entry_title):
    title_lower, entry_lower = normalize_title(book_title), normalize_title(entry_title)
    if not title_lower or not entry_lower:
        return 0
    if title_lower == entry_lower:
        return 100
    book_words, entry_words = title_words(title_lower), title_words(entry_lower)
    common_words = book_words & entry_words
    if not common_words:
        return 0
    filler = {'a', 'an', 'the', 'and', 'or', 'but'}
    title_sig, entry_sig = book_words - filler, entry_words - filler
    common_sig = title_sig & entry_sig
    if len(common_words) == min(len(book_words), len(entry_words)):
        return 85
    if len(common_sig) == min(len(title_sig), len(entry_sig)) and common_sig:
        return 80
    return int((len(common_words) / max(len(book_words), len(entry_words))) * 100)


def find_library_match(book, catalogue=None):
    catalogue = catalogue if catalogue is not None else get_library_catalogue()
    book_title = book.get('title', '')
    wanted_isbn = re.sub(r'[^0-9Xx]', '', book.get('isbn', ''))
    wanted_author = normalize_title(book.get('author', ''))
    best, best_score = None, 0
    for entry in catalogue:
        entry_isbn = re.sub(r'[^0-9Xx]', '', entry.get('isbn', ''))
        if wanted_isbn and entry_isbn and wanted_isbn == entry_isbn:
            score = 100
        else:
            if wanted_author and normalize_title(entry.get('author', '')) != wanted_author:
                continue
            score = title_match_score(book_title, entry.get('title', ''))
        if score >= 70 and score > best_score:
            acquisition = next((link.get('href') for link in entry.get('links', []) if 'acquisition' in (link.get('rel') or '')), None)
            best = {'in_library': True, 'match_score': score, 'opds_title': entry.get('title', ''), 'download_url': acquisition}
            best_score = score
            if score == 100:
                break
    return best or {'in_library': False}


@bp.route('/image-proxy')
def image_proxy():
    url = request.args.get('url')
    if not url:
        return '', 404
    if url.startswith('/'):
        base = GRIMMORY_URL.split('/api/v1/opds')[0] if '/api/v1/opds' in GRIMMORY_URL else GRIMMORY_URL.rsplit('/', 1)[0]
        url = base + url
    try:
        validate_url(url, allowed_origins=IMAGE_PROXY_ORIGINS)
        headers = {'User-Agent': 'Mozilla/5.0'}
        if get_origin(url) in GRIMMORY_ORIGINS:
            headers.update(grimmory_headers())
        resp = get_with_allowed_redirects(url, allowed_origins={get_origin(url)}, headers=headers, timeout=15)
        resp.raise_for_status()
        return resp.content, resp.status_code, {'Content-Type': resp.headers.get('Content-Type', 'image/jpeg'), 'Cache-Control': 'public, max-age=604800, immutable'}
    except Exception as e:
        print(f'[Cover] Error: {type(e).__name__}', flush=True)
        return '', 404


@bp.route('/browse')
def browse():
    target_url = request.args.get('url') or GRIMMORY_URL
    if not target_url.startswith('http'):
        target_url = GRIMMORY_URL.rstrip('/') + target_url
    try:
        def load():
            resp = get_with_allowed_redirects(target_url, allowed_origins=GRIMMORY_ORIGINS, headers=grimmory_headers(), timeout=20)
            resp.raise_for_status()
            return parse_opds_feed(resp.content, target_url)
        parsed = cached_load(f'grimmory:browse:{target_url}', 'grimmory', 60, load, stale_ttl=300, lock_seconds=25)
        entries = parsed['entries']
        is_acquisition = any(any('acquisition' in (link['rel'] or '') for link in entry['links']) for entry in entries)
        return jsonify({'entries': entries, 'type': 'acquisition' if is_acquisition else 'navigation'})
    except requests.exceptions.HTTPError as e:
        return jsonify({'error': f'HTTP Error: {type(e).__name__}'}), e.response.status_code
    except Exception as e:
        return jsonify({'error': f'Connection Error: {type(e).__name__}'}), 500


@bp.route('/check-library', methods=['POST'])
def check_library():
    data = request.get_json(silent=True) or {}
    author = data.get('author', '')
    books = data.get('books') or [{'title': title, 'author': author} for title in data.get('titles', [])]
    try:
        catalogue = get_library_catalogue()
        return jsonify({'results': {book['title']: find_library_match(book, catalogue) for book in books if book.get('title')}})
    except Exception as e:
        print(f'[ERROR] Library check failed: {type(e).__name__}', flush=True)
        return jsonify({'results': {}})


@bp.route('/authors')
def authors():
    def load():
        root_url = GRIMMORY_URL.rstrip('/') + '/authors'
        root_response = get_with_allowed_redirects(
            root_url, allowed_origins=GRIMMORY_ORIGINS, headers=grimmory_headers(), timeout=20
        )
        root_response.raise_for_status()
        root_entries = parse_opds_feed(root_response.content, root_url)['entries']
        section_urls = []
        direct_authors = []
        for entry in root_entries:
            subsection = next(
                (link.get('href') for link in entry.get('links', []) if 'subsection' in (link.get('rel') or '')), ''
            )
            title = (entry.get('title') or '').strip()
            is_letter_bucket = bool(
                subsection and (
                    re.fullmatch(r'[A-Za-z]', title)
                    or title.casefold() in {'#', '0-9', 'other'}
                    or re.fullmatch(r'[A-Za-z]\s*(authors?)?', title, flags=re.I)
                )
            )
            if is_letter_bucket:
                section_urls.append(subsection)
            elif subsection:
                direct_authors.append(entry)

        def fetch_section(url):
            response = get_with_allowed_redirects(
                url, allowed_origins=GRIMMORY_ORIGINS, headers=grimmory_headers(), timeout=20
            )
            response.raise_for_status()
            return parse_opds_feed(response.content, url)['entries']

        author_entries = list(direct_authors)
        with ThreadPoolExecutor(max_workers=6) as executor:
            futures = [executor.submit(fetch_section, url) for url in section_urls]
            for future in as_completed(futures):
                try:
                    author_entries.extend(
                        entry for entry in future.result()
                        if any('subsection' in (link.get('rel') or '') for link in entry.get('links', []))
                    )
                except Exception as e:
                    print(f'[Authors] Catalogue section failed: {type(e).__name__}', flush=True)

        unique = {}
        for entry in author_entries:
            name = (entry.get('title') or '').strip()
            if name:
                unique[name.casefold()] = entry
        return {'entries': sorted(unique.values(), key=lambda entry: (entry.get('title') or '').casefold())}
    try:
        return jsonify(cached_load('grimmory:authors:v1', 'grimmory', 24 * 60 * 60, load, stale_ttl=7 * 24 * 60 * 60, lock_seconds=60))
    except Exception:
        print('[Authors] Catalogue lookup failed', flush=True)
        return jsonify({'entries': []})


@bp.route('/author-profile')
def author_profile():
    name = request.args.get('name', '').strip()
    if not name:
        return jsonify({}), 400
    try:
        search = get_cached_json(
            f'openlibrary:author:{name}', urljoin(OPENLIBRARY_BASE_URL, '/search/authors.json'),
            OPENLIBRARY_ORIGINS, headers=openlibrary_headers(), params={'q': name, 'limit': 5},
            cache_seconds=30 * 24 * 60 * 60
        )
        candidates = search.get('docs') or []
        exact = next((item for item in candidates if (item.get('name') or '').casefold() == name.casefold()), None)
        author = exact or (candidates[0] if candidates else {})
        key = (author.get('key') or '').replace('/authors/', '')
        profile = {}
        if key:
            profile = get_cached_json(
                f'openlibrary:author-profile:{key}', urljoin(OPENLIBRARY_BASE_URL, f'/authors/{key}.json'),
                OPENLIBRARY_ORIGINS, headers=openlibrary_headers(), cache_seconds=30 * 24 * 60 * 60
            )
        bio = profile.get('bio') or author.get('bio') or ''
        if isinstance(bio, dict):
            bio = bio.get('value', '')
        photos = profile.get('photos') or []
        photo_id = (photos[0] if photos else None) or author.get('cover_i')
        return jsonify({
            'name': profile.get('name') or author.get('name') or name,
            'bio': clean_html(bio),
            'image_url': f'https://covers.openlibrary.org/a/id/{photo_id}-M.jpg' if photo_id else ''
        })
    except Exception as e:
        print(f'[Author] Profile lookup failed: {type(e).__name__}', flush=True)
        return jsonify({})


@bp.route('/metadata', methods=['POST'])
def metadata():
    data = request.get_json(silent=True) or {}
    title = data.get('title', '').strip()
    if not title:
        return jsonify({'error': 'No title provided'}), 400
    try:
        return jsonify(resolve_metadata(title, data.get('author', ''), data.get('isbn', '')))
    except Exception as e:
        print(f'[ERROR] Metadata lookup failed: {type(e).__name__}', flush=True)
        return jsonify({})


@bp.route('/metadata-batch', methods=['POST'])
def metadata_batch():
    data = request.get_json(silent=True) or {}
    books = (data.get('books') or [])[:20]

    def enrich(book):
        metadata = {}
        if book.get('source') == 'openlibrary' and book.get('source_id'):
            try:
                metadata['description'] = openlibrary_work_description(book['source_id'])
            except Exception:
                pass
        if not metadata.get('description') or not book.get('cover_url') or not book.get('isbn'):
            resolved = resolve_metadata(book.get('title', ''), book.get('author', ''), book.get('isbn', ''))
            for key, value in resolved.items():
                if value and not metadata.get(key):
                    metadata[key] = value
        return {'index': book.get('index'), 'metadata': metadata}

    try:
        with ThreadPoolExecutor(max_workers=4) as executor:
            results = list(executor.map(enrich, books))
        return jsonify({'results': results})
    except Exception:
        print('[ERROR] Batch metadata lookup failed', flush=True)
        return jsonify({'results': []})
