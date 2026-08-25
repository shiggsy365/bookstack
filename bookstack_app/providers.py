import html
import re


def clean_html(raw_html):
    if not raw_html:
        return ''
    cleantext = html.unescape(raw_html)
    cleantext = re.sub(r'<[^>]+>', '', cleantext)
    return re.sub(r'\s+', ' ', cleantext).strip()


def first_value(value, default=None):
    if isinstance(value, list):
        return value[0] if value else default
    return value if value is not None else default


def normalize_openlibrary_book(book):
    authors = book.get('author_name') or book.get('authors') or []
    if isinstance(authors, str):
        authors = [authors]
    elif authors and isinstance(authors[0], dict):
        authors = [author.get('name', '') for author in authors if author.get('name')]
    cover_id = book.get('cover_i') or book.get('cover_id')
    description = book.get('description') or ''
    if isinstance(description, dict):
        description = description.get('value', '')
    return {
        'source': 'openlibrary', 'source_id': book.get('key', ''),
        'title': book.get('title', 'Unknown Title'), 'authors': authors,
        'author': first_value(authors, ''), 'isbn': first_value(book.get('isbn'), ''),
        'cover_url': f'https://covers.openlibrary.org/b/id/{cover_id}-M.jpg' if cover_id else '',
        'description': clean_html(description),
        'published_year': book.get('first_publish_year') or book.get('first_publish_date') or '',
        'genres': book.get('subject') or book.get('subjects') or [],
        'in_library': None, 'library_download_url': None
    }


def normalize_openlibrary_books(books):
    normalized, seen = [], set()
    for book in books:
        item = normalize_openlibrary_book(book)
        identity = item['source_id'] or (item['title'].lower(), item['author'].lower())
        if item['title'] and identity not in seen:
            normalized.append(item)
            seen.add(identity)
    return normalized


def normalize_google_book(book):
    volume = book.get('volumeInfo', {})
    identifiers = volume.get('industryIdentifiers') or []
    isbn = next((item.get('identifier', '') for item in identifiers if item.get('type') in ('ISBN_13', 'ISBN_10')), '')
    images = volume.get('imageLinks') or {}
    cover_url = images.get('thumbnail') or images.get('smallThumbnail') or ''
    if cover_url.startswith('http://'):
        cover_url = 'https://' + cover_url[7:]
    authors = volume.get('authors') or []
    return {
        'source': 'googlebooks', 'source_id': book.get('id', ''),
        'title': volume.get('title', 'Unknown Title'), 'authors': authors,
        'author': first_value(authors, ''), 'isbn': isbn, 'cover_url': cover_url,
        'description': clean_html(volume.get('description', '')),
        'published_year': (volume.get('publishedDate') or '')[:4],
        'genres': volume.get('categories') or [],
        'in_library': None, 'library_download_url': None
    }


def normalize_google_books(books):
    normalized, seen = [], set()
    for book in books:
        item = normalize_google_book(book)
        identity = item['isbn'] or item['source_id'] or (item['title'].lower(), item['author'].lower())
        if item['title'] and identity not in seen:
            normalized.append(item)
            seen.add(identity)
    return normalized


def metadata_fields(book):
    return {
        key: book.get(key)
        for key in ('source', 'title', 'authors', 'isbn', 'cover_url', 'description', 'published_year')
    }
