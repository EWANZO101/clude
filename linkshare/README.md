# LinkShare

Anonymous photo/video upload → shareable link → auto-deletes after 12 hours.

## What it does
- Drag/drop or click to upload an image or video (jpg/png/gif/webp/mp4/mov/webm/avi/mkv)
- Returns a link like `https://link.opslabsystems.cloud/v/aB3xK9pQ`
- Background job checks every 5 min and deletes any file+DB row past its 12h expiry
- Expired/missing links show a "gone" page (404)
- No accounts, no login

## Local test
```
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python app.py
```
Visit http://localhost:5000

## Deploy on swift1

```bash
sudo mkdir -p /opt/linkshare
sudo chown $USER:$USER /opt/linkshare
# copy all files from this zip into /opt/linkshare

cd /opt/linkshare
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
deactivate

sudo chown -R www-data:www-data /opt/linkshare

sudo cp deploy/linkshare.service /etc/systemd/system/linkshare.service
sudo nano /etc/systemd/system/linkshare.service   # set SECRET_KEY to something random

sudo systemctl daemon-reload
sudo systemctl enable --now linkshare
sudo systemctl status linkshare

sudo cp deploy/nginx-link.opslabsystems.cloud.conf /etc/nginx/sites-available/link.opslabsystems.cloud
sudo ln -s /etc/nginx/sites-available/link.opslabsystems.cloud /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

sudo certbot --nginx -d link.opslabsystems.cloud
```

## Config (env vars in the systemd unit)
- `EXPIRE_HOURS` — default 12
- `MAX_UPLOAD_MB` — default 500
- `SECRET_KEY` — set this to something random in prod

## Notes
- Uses SQLite (`linkshare.db`) for metadata + a plain `uploads/` folder on disk. Fine for this scale; no separate DB server needed.
- Gunicorn is set to **1 worker with 4 threads** on purpose — the cleanup job runs inside the app process (APScheduler). Multiple workers would each run their own scheduler and duplicate the cleanup (harmless but wasteful). If you ever need more throughput, move to `gunicorn -w N` and run cleanup as a separate cron hitting a `/internal/cleanup` route instead, or move the scheduler out to a `cron` + `flask cleanup` CLI command.
- `nginx` `client_max_body_size` must be >= `MAX_UPLOAD_MB` or big uploads get a 413 from nginx before Flask ever sees them.
- Files are stored outside `static/` and only served through `/f/<code>` and `/d/<code>`, which both check expiry before serving — so even if the 5-min cleanup job hasn't run yet, an expired file won't be served.
