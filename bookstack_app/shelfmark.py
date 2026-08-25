
import requests
from flask import Blueprint, jsonify, request

from .config import SHELFMARK_URL
from .opds import get_cached_booklore_entries

bp = Blueprint('shelfmark', __name__, url_prefix='/api/shelfmark')


def release_items(payload):
    if isinstance(payload, list):
        items = payload
    elif isinstance(payload, dict):
        items = payload.get('releases') or payload.get('results') or []
    else:
        items = []

    def sort_key(item):
        try:
            seeders = int(item.get('seeders') or 0)
        except (TypeError, ValueError):
            seeders = 0
        try:
            size = int(item.get('size_bytes') or item.get('size') or 0)
        except (TypeError, ValueError):
            size = 0
        return seeders, size

    items.sort(key=sort_key, reverse=True)
    return items


@bp.route('/search')
def search():
    query = request.args.get('q', '').strip()
    title = request.args.get('title', '').strip()
    if not query:
        return jsonify({'error': 'No query provided'}), 400
    books, seen_titles = [], set()

    try:
        for entry in get_cached_booklore_entries(title or query):
            acquisition = next((link.get('href') for link in entry.get('links', []) if 'acquisition' in (link.get('rel') or '')), '')
            cover_url = next((link.get('href') for link in entry.get('links', []) if 'thumbnail' in (link.get('rel') or '') or 'image' in (link.get('rel') or '')), '')
            if not acquisition:
                continue
            entry_title = entry.get('title') or 'Unknown Title'
            seen_titles.add(' '.join(entry_title.casefold().split()))
            books.append({
                'md5': '', 'title': entry_title,
                'authors': [entry.get('author')] if entry.get('author') else [],
                'isbn': entry.get('isbn') or '', 'coverUrl': cover_url,
                'description': entry.get('description') or '',
                'published_year': '', 'genres': [],
                'library_download_url': acquisition
            })
    except Exception as e:
        print(f'[Search] Library search failed: {type(e).__name__}', flush=True)

    manual_title = title or query
    if ' '.join(manual_title.casefold().split()) not in seen_titles:
        books.append({
            'md5': f'manual:{manual_title}', 'title': manual_title, 'authors': [],
            'isbn': '', 'coverUrl': '', 'size': 'Universal',
            'format': 'Universal', 'description': 'Search all enabled Shelfmark release sources.',
            'published_year': '', 'genres': []
        })
    return jsonify(books)


@bp.route('/releases')
def releases():
    md5 = request.args.get('md5')
    if not md5 or ':' not in md5:
        return jsonify({'error': 'Invalid MD5 format for release search'}), 400
    provider, book_id = md5.split(':', 1)
    try:
        params = {'provider': provider, 'book_id': book_id}
        if provider == 'manual':
            params = {'provider': 'manual', 'book_id': 'manual-search', 'title': book_id, 'content_type': 'ebook'}
        resp = requests.get(f'{SHELFMARK_URL.rstrip("/")}/api/releases', params=params, timeout=120)
        resp.raise_for_status()
        return jsonify(release_items(resp.json()))
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@bp.route('/request-releases')
def request_releases():
    """Search Shelfmark release sources without a metadata-provider round trip."""
    stage = request.args.get('stage', '').strip()
    isbn = ''.join(ch for ch in request.args.get('isbn', '') if ch.isdigit() or ch in 'Xx')
    title = request.args.get('title', '').strip()
    author = request.args.get('author', '').strip()

    if stage == 'isbn':
        if not isbn:
            return jsonify({'error': 'No ISBN provided'}), 400
        params = [('source', 'direct_download'), ('query', isbn), ('isbn', isbn), ('content_type', 'ebook')]
    elif stage in ('author_title', 'title'):
        if not title:
            return jsonify({'error': 'No title provided'}), 400
        params = {'provider': 'manual', 'book_id': f'manual-{stage}', 'title': title, 'content_type': 'ebook'}
        if stage == 'author_title' and author:
            params['author'] = author
    else:
        return jsonify({'error': 'Invalid request search stage'}), 400

    try:
        resp = requests.get(f'{SHELFMARK_URL.rstrip("/")}/api/releases', params=params, timeout=120)
        resp.raise_for_status()
        return jsonify(release_items(resp.json()))
    except Exception as e:
        print(f'[ERROR] Shelfmark request release search failed ({stage}): {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to search Shelfmark releases'}), 502


@bp.route('/download', methods=['POST'])
def download():
    data = request.get_json(silent=True) or {}
    try:
        base = SHELFMARK_URL.rstrip('/')
        if 'source' in data and ('source_id' in data or 'id' in data):
            resp = requests.post(f'{base}/api/releases/download', json=data, timeout=120)
        elif data.get('md5') and ':' not in data['md5']:
            resp = requests.get(f'{base}/api/download', params={'id': data['md5']}, timeout=120)
        else:
            return jsonify({'error': 'Please use release selection for this item'}), 400
        resp.raise_for_status()
        return jsonify(resp.json())
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@bp.route('/queue')
def queue():
    try:
        resp = requests.get(f'{SHELFMARK_URL.rstrip("/")}/api/status', timeout=120)
        resp.raise_for_status()
        data = resp.json()
        if 'complete' in data:
            data['done'] = data.pop('complete')
        return jsonify(data)
    except Exception as e:
        return jsonify({'error': str(e)}), 500
