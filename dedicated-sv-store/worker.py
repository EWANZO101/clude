import os

from redis import Redis
from rq import Worker

listen = ["emails", "default", "hardware_sync", "notifications", "webhooks"]

if __name__ == "__main__":
    redis_url = os.environ.get("REDIS_URL", "redis://localhost:6379/0")
    conn = Redis.from_url(redis_url)
    worker = Worker(listen, connection=conn)
    worker.work()
