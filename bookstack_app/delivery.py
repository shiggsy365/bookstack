import os
import smtplib
import tempfile
from contextlib import closing
from email import encoders
from email.mime.base import MIMEBase
from email.mime.multipart import MIMEMultipart
from urllib.parse import unquote, urljoin, urlparse

from flask import Blueprint, jsonify, request

from .config import (
    BOOKLORE_URL, MAX_KINDLE_ATTACHMENT_BYTES, MAX_KINDLE_ATTACHMENT_MB,
    SMTP_PASS, SMTP_PORT, SMTP_SERVER, SMTP_USER
)
from .opds import BOOKLORE_ORIGINS, booklore_headers
from .security import get_with_allowed_redirects

bp = Blueprint('delivery', __name__, url_prefix='/api/opds')


def get_filename(resp, download_url):
    disposition = resp.headers.get('content-disposition', '')
    if 'filename=' in disposition:
        filename = disposition.split('filename=', 1)[1].strip().strip('"\'')
    else:
        filename = unquote(urlparse(download_url).path.rsplit('/', 1)[-1]) or 'book.epub'
    return os.path.basename(filename) or 'book.epub'


@bp.route('/send-to-kindle', methods=['POST'])
def send_to_kindle():
    kindle_email = request.cookies.get('kindle_email', '')
    data = request.get_json(silent=True) or {}
    download_url = data.get('url')
    if not kindle_email:
        return jsonify({'error': 'Kindle email not configured'}), 400
    if not download_url:
        return jsonify({'error': 'No URL provided'}), 400
    if not SMTP_USER or not SMTP_PASS:
        return jsonify({'error': 'SMTP credentials not configured in server'}), 500
    if download_url.startswith('/'):
        download_url = urljoin(BOOKLORE_URL.rstrip('/') + '/', download_url)

    try:
        with closing(get_with_allowed_redirects(
                download_url, allowed_origins=BOOKLORE_ORIGINS,
                headers=booklore_headers(), timeout=30, stream=True
        )) as resp:
            resp.raise_for_status()
            try:
                declared_size = int(resp.headers.get('content-length') or 0)
            except ValueError:
                declared_size = 0
            if declared_size > MAX_KINDLE_ATTACHMENT_BYTES:
                return jsonify({'error': f'Book exceeds the {MAX_KINDLE_ATTACHMENT_MB}MB Kindle attachment limit'}), 413

            filename, size = get_filename(resp, download_url), 0
            with tempfile.TemporaryFile() as attachment:
                for chunk in resp.iter_content(chunk_size=64 * 1024):
                    if not chunk:
                        continue
                    size += len(chunk)
                    if size > MAX_KINDLE_ATTACHMENT_BYTES:
                        return jsonify({'error': f'Book exceeds the {MAX_KINDLE_ATTACHMENT_MB}MB Kindle attachment limit'}), 413
                    attachment.write(chunk)
                attachment.seek(0)
                part = MIMEBase('application', 'octet-stream')
                part.set_payload(attachment.read())
        encoders.encode_base64(part)
        part.add_header('Content-Disposition', 'attachment', filename=filename)

        msg = MIMEMultipart()
        msg['From'], msg['To'], msg['Subject'] = SMTP_USER, kindle_email, 'Book from OPDS'
        msg.attach(part)
        with smtplib.SMTP(SMTP_SERVER, SMTP_PORT, timeout=30) as server:
            server.starttls()
            server.login(SMTP_USER, SMTP_PASS)
            server.send_message(msg)
        return jsonify({'status': 'sent', 'filename': filename, 'size': size})
    except Exception as e:
        return jsonify({'error': f'Delivery error: {e}'}), 500
