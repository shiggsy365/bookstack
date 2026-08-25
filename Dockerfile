FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY bookstack_app ./bookstack_app
COPY templates ./templates

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--worker-class", "gthread", "--workers", "2", "--threads", "4", "--timeout", "130", "app:app"]
