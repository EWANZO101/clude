FROM node:20-slim AS assets
WORKDIR /build
COPY package.json package-lock.json* ./
RUN npm install
COPY tailwind.config.js ./
COPY app/templates ./app/templates
COPY app/static/css/input.css ./app/static/css/input.css
RUN npx tailwindcss -i ./app/static/css/input.css -o ./app/static/css/output.css --minify


FROM python:3.11-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq5 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .
COPY --from=assets /build/app/static/css/output.css ./app/static/css/output.css

RUN useradd --create-home --uid 1000 appuser \
    && mkdir -p instance instance/uploads app/static/uploads \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

CMD ["gunicorn", "-c", "gunicorn.conf.py", "wsgi:app"]
