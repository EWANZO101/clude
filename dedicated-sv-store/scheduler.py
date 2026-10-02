import os
from datetime import datetime, timedelta

from redis import Redis
from rq_scheduler import Scheduler

from app.tasks.scheduled import mark_overdue_invoices, cleanup_expired_tokens

if __name__ == "__main__":
    redis_url = os.environ.get("REDIS_URL", "redis://localhost:6379/0")
    scheduler = Scheduler(connection=Redis.from_url(redis_url), queue_name="default")

    for job in scheduler.get_jobs():
        scheduler.cancel(job)

    now = datetime.utcnow()
    scheduler.schedule(scheduled_time=now, func=mark_overdue_invoices, interval=int(timedelta(hours=1).total_seconds()))
    scheduler.schedule(scheduled_time=now, func=cleanup_expired_tokens, interval=int(timedelta(hours=6).total_seconds()))

    scheduler.run()
