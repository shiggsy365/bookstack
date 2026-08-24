import base64
import re
from concurrent.futures import ThreadPoolExecutor, as_completed
import time
import xml.etree.ElementTree as ET
from urllib.parse import quote_plus, urljoin

import requests
from flask import Blueprint, jsonify, request

from .config import BOOKLORE_PASS, BOOKLORE_URL, BOOKLORE_USER, SHELFMARK_URL
from .discovery import OPENLIBRARY_BASE_URL, OPENLIBRARY_ORIGINS, get_cached_json, openlibrary_headers
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
BOOKLORE_ORIGINS = {get_origin(BOOKLORE_URL)}
IMAGE_PROXY_ORIGINS = BOOKLORE_ORIGINS | {get_origin(SHELFMARK_URL)}
LIBRARY_SEARCH_CACHE_SECONDS = 5 * 60
LIBRARY_SEARCH_CACHE = {}


def booklore_headers():
    auth_str = f'{BOOKLORE_USER}:{BOOKLORE_PASS}'
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


def get_cached_booklore_entries(query):
    query, now = (query or '').strip(), time.time()
    cached = LIBRARY_SEARCH_CACHE.get(query)
    if cached and cached['expires_at'] > now:
        return cached['entries']
    search_url = f'{BOOKLORE_URL}/catalog?q={quote_plus(query)}'
    resp = get_with_allowed_redirects(search_url, allowed_origins=BOOKLORE_ORIGINS, headers=booklore_headers(), timeout=120)
    if resp.status_code != 200:
        return []
    entries = parse_opds_feed(resp.content, search_url)['entries']
    LIBRARY_SEARCH_CACHE[query] = {'entries': entries, 'expires_at': now + LIBRARY_SEARCH_CACHE_SECONDS}
    return entries


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


def find_library_match(book):
    book_title = book.get('title', '')
    isbn = re.sub(r'[^0-9Xx]', '', book.get('isbn', ''))
    queries = [(isbn, True)] if isbn else []
    queries.append((book.get('author') or book_title, False))
    best, best_score = None, 0
    for query, is_isbn in queries:
        for entry in get_cached_booklore_entries(query):
            score = title_match_score(book_title, entry.get('title', ''))
            if is_isbn and score < 70:
                continue
            if score >= 70 and score > best_score:
                acquisition = next((link.get('href') for link in entry.get('links', []) if 'acquisition' in (link.get('rel') or '')), None)
                best = {'in_library': True, 'match_score': score, 'opds_title': entry.get('title', ''), 'download_url': acquisition}
                best_score = score
        if best:
            break
    return best or {'in_library': False}


@bp.route('/image-proxy')
def image_proxy():
    url = request.args.get('url')
    if not url:
        return '', 404
    if url.startswith('/'):
        base = BOOKLORE_URL.split('/api/v1/opds')[0] if '/api/v1/opds' in BOOKLORE_URL else BOOKLORE_URL.rsplit('/', 1)[0]
        url = base + url
    try:
        validate_url(url, allowed_origins=IMAGE_PROXY_ORIGINS)
        headers = {'User-Agent': 'Mozilla/5.0'}
        if get_origin(url) in BOOKLORE_ORIGINS:
            headers.update(booklore_headers())
        resp = get_with_allowed_redirects(url, allowed_origins={get_origin(url)}, headers=headers, timeout=120)
        resp.raise_for_status()
        return resp.content, resp.status_code, {'Content-Type': resp.headers.get('Content-Type', 'image/jpeg')}
    except Exception as e:
        print(f'[Cover] Error: {e}', flush=True)
        return '', 404


@bp.route('/browse')
def browse():
    target_url = request.args.get('url') or BOOKLORE_URL
    if not target_url.startswith('http'):
        target_url = BOOKLORE_URL.rstrip('/') + target_url
    try:
        resp = get_with_allowed_redirects(target_url, allowed_origins=BOOKLORE_ORIGINS, headers=booklore_headers(), timeout=120)
        resp.raise_for_status()
        parsed = parse_opds_feed(resp.content, target_url)
        entries = parsed['entries']
        is_acquisition = any(any('acquisition' in (link['rel'] or '') for link in entry['links']) for entry in entries)
        return jsonify({'entries': entries, 'type': 'acquisition' if is_acquisition else 'navigation'})
    except requests.exceptions.HTTPError as e:
        return jsonify({'error': f'HTTP Error: {e}'}), e.response.status_code
    except Exception as e:
        return jsonify({'error': f'Connection Error: {e}'}), 500


@bp.route('/check-library', methods=['POST'])
def check_library():
    data = request.get_json(silent=True) or {}
    author = data.get('author', '')
    books = data.get('books') or [{'title': title, 'author': author} for title in data.get('titles', [])]
    try:
        return jsonify({'results': {book['title']: find_library_match(book) for book in books if book.get('title')}})
    except Exception as e:
        print(f'[ERROR] Library check failed: {e}', flush=True)
        return jsonify({'results': {}})


@bp.route('/authors')
def authors():
    try:
        root_url = BOOKLORE_URL.rstrip('/') + '/authors'
        root_response = get_with_allowed_redirects(
            root_url, allowed_origins=BOOKLORE_ORIGINS, headers=booklore_headers(), timeout=120
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
                url, allowed_origins=BOOKLORE_ORIGINS, headers=booklore_headers(), timeout=120
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
                    print(f'[Authors] Catalogue section failed: {e}', flush=True)

        unique = {}
        for entry in author_entries:
            name = (entry.get('title') or '').strip()
            if name:
                unique[name.casefold()] = entry
        return jsonify({'entries': sorted(unique.values(), key=lambda entry: (entry.get('title') or '').casefold())})
    except Exception as e:
        print(f'[Authors] Catalogue lookup failed: {e}', flush=True)
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
        print(f'[Author] Profile lookup failed: {e}', flush=True)
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
        print(f'[ERROR] Metadata lookup failed: {e}', flush=True)
        return jsonify({})
