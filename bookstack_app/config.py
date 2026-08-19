import os

SHELFMARK_URL = os.environ.get('SHELFMARK_URL', 'http://shelfmark:8084')
BOOKLORE_URL = os.environ.get('BOOKLORE_URL', 'http://booklore:6060/api/v1/opds')
BOOKLORE_USER = os.environ.get('BOOKLORE_USER', '')
BOOKLORE_PASS = os.environ.get('BOOKLORE_PASS', '')
SMTP_SERVER = os.environ.get('SMTP_SERVER', 'smtp.gmail.com')
SMTP_PORT = int(os.environ.get('SMTP_PORT', '587'))
SMTP_USER = os.environ.get('SMTP_USER', '')
SMTP_PASS = os.environ.get('SMTP_PASS', '')
OPENLIBRARY_CONTACT = os.environ.get('OPENLIBRARY_CONTACT', '')
GOOGLE_BOOKS_API_KEY = os.environ.get('GOOGLE_BOOKS_API_KEY', '')
NYT_BOOKS_API_KEY = os.environ.get('NYT_BOOKS_API_KEY', '')
HARDCOVER_API_KEY = os.environ.get('HARDCOVER_API_KEY', '')
MAX_KINDLE_ATTACHMENT_MB = int(os.environ.get('MAX_KINDLE_ATTACHMENT_MB', '25'))
MAX_KINDLE_ATTACHMENT_BYTES = MAX_KINDLE_ATTACHMENT_MB * 1024 * 1024

if not BOOKLORE_USER or not BOOKLORE_PASS:
    raise RuntimeError('BOOKLORE_USER and BOOKLORE_PASS must be configured')
