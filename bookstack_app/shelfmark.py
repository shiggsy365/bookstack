from urllib.parse import quote_plus

import requests
from flask import Blueprint, jsonify, request

from .config import SHELFMARK_URL
from .opds import get_cached_booklore_entries

bp = Blueprint('shelfmark', __name__, url_prefix='/api/shelfmark')


@bp.route('/search')
def search():
    query = request.args.get('q', '').strip()
    title = request.args.get('title', '').strip()
    if not query:
        return jsonify({'error': 'No query provided'}), 400
    base = SHELFMARK_URL.rstrip('/')
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
        print(f'[Search] Library search failed: {e}', flush=True)

    try:
        queries = [query]
        if title and title.casefold() != query.casefold():
            queries.append(title)
        raw_books = []
        for search_query in queries:
            resp = requests.get(f'{base}/api/metadata/search', params={'query': search_query}, timeout=120)
            resp.raise_for_status()
            data = resp.json()
            raw_books = (data.get('books') or data.get('results') or []) if isinstance(data, dict) else data
            if raw_books:
                break
        for book in raw_books or []:
            provider = book.get('provider') or book.get('source')
            book_id = book.get('provider_id') or book.get('source_id') or book.get('id')
            if not book_id:
                continue
            # Handle composite ids like "hardcover_319563" when provider is not a separate field
            if not provider and isinstance(book_id, str) and '_' in book_id:
                parts = book_id.rsplit('_', 1)
                if len(parts) == 2 and parts[1].isdigit():
                    provider, book_id = parts[0], parts[1]
            if not provider:
                continue
            book_title = book.get('title') or 'Unknown Title'
            title_key = ' '.join(book_title.casefold().split())
            if title_key in seen_titles:
                continue
            seen_titles.add(title_key)
            cover_url = book.get('cover_url') or book.get('coverUrl') or book.get('preview') or ''
            if cover_url.startswith('/'):
                cover_url = f'/api/opds/image-proxy?url={quote_plus(base + cover_url)}'
            books.append({
                'md5': f'{provider}:{book_id}', 'title': book_title,
                'authors': book.get('authors', []) or ([book.get('author')] if book.get('author') else []),
                'isbn': book.get('isbn') or book.get('isbn_13') or book.get('isbn_10') or '',
                'coverUrl': cover_url, 'size': 'Universal', 'language': book.get('language'),
                'format': 'Universal', 'description': book.get('description'),
                'published_year': book.get('published_year') or book.get('year') or '',
                'genres': book.get('genres') or []
            })
        return jsonify(books)
    except Exception as e:
        print(f'[ERROR] Shelfmark search failed: {e}', flush=True)
        if books:
            return jsonify(books)
        return jsonify({'error': str(e)}), 502


@bp.route('/releases')
def releases():
    md5 = request.args.get('md5')
    if not md5 or ':' not in md5:
        return jsonify({'error': 'Invalid MD5 format for release search'}), 400
    provider, book_id = md5.split(':', 1)
    try:
        resp = requests.get(f'{SHELFMARK_URL.rstrip("/")}/api/releases', params={'provider': provider, 'book_id': book_id}, timeout=120)
        resp.raise_for_status()
        payload = resp.json()
        if isinstance(payload, list):
            releases_data = payload
        elif isinstance(payload, dict):
            releases_data = payload.get('releases') or payload.get('results') or []
        else:
            releases_data = []
        def sort_key(item):
            try:
                seeders = int(item.get('seeders') or 0)
            except (TypeError, ValueError):
                seeders = 0
            try:
                size = int(item.get('size') or 0)
            except (TypeError, ValueError):
                size = 0
            return seeders, size
        releases_data.sort(key=sort_key, reverse=True)
        return jsonify(releases_data)
    except Exception as e:
        return jsonify({'error': str(e)}), 500


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
