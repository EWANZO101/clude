from redis import Redis
from rq import Queue

from flask import current_app


def get_redis_connection():
    return Redis.from_url(current_app.config["REDIS_URL"])


def get_queue(name="default"):
    return Queue(name, connection=get_redis_connection())


def enqueue(func, *args, queue_name="default", **kwargs):
    return get_queue(queue_name).enqueue(func, *args, **kwargs)
