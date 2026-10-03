"""
TeamTreck Agent CLI.

Usage:
    python -m agent.cli setup                  Configure server URL + token
    python -m agent.cli run                    Run the agent in the foreground (sync loop)
    python -m agent.cli start [--project ID] [--note "..."]
    python -m agent.cli pause
    python -m agent.cli resume
    python -m agent.cli stop
    python -m agent.cli status
"""
import argparse
from agent.config import load_config, set_token, set_server_url
from agent.service import AgentService


def cmd_setup(args):
    print('TeamTreck Agent Setup')
    print('----------------------')
    cfg = load_config()

    server_url = input(f"Server URL [{cfg['server_url']}]: ").strip()
    if server_url:
        set_server_url(server_url)

    token = input('Agent token (from the Monitoring page in TeamTreck): ').strip()
    if token:
        set_token(token)

    print('Saved. Testing connection...')
    service = AgentService()
    service.client.reload_config()
    if service.client.ping():
        print('Connected successfully.')
    else:
        print('Could not reach the server. Check the URL and token, then re-run setup.')


def cmd_run(args):
    service = AgentService()
    print('Agent running. Press Ctrl+C to stop.')
    service.run_forever()


def cmd_start(args):
    service = AgentService()
    ok = service.start_timer(project_id=args.project, task_id=args.task, note=args.note or '')
    print('Timer started.' if ok else 'Failed to start timer (check connection/token).')


def cmd_pause(args):
    service = AgentService()
    ok = service.pause_timer()
    print('Timer paused.' if ok else 'No active timer to pause, or request failed.')


def cmd_resume(args):
    service = AgentService()
    ok = service.resume_timer()
    print('Timer resumed.' if ok else 'No paused timer to resume, or request failed.')


def cmd_stop(args):
    service = AgentService()
    ok = service.stop_timer()
    print('Timer stopped.' if ok else 'No active timer to stop, or request failed.')


def cmd_status(args):
    service = AgentService()
    s = service.status()
    print(f"Server reachable: {s.get('server_reachable')}")
    print(f"Queued records waiting to sync: {s.get('queue_size')}")
    if s.get('active'):
        print(f"Timer: {s.get('status')} - {s.get('duration_hms')}")
    else:
        print('Timer: not running')


def main():
    parser = argparse.ArgumentParser(prog='teamtreck-agent')
    sub = parser.add_subparsers(dest='command', required=True)

    sub.add_parser('setup').set_defaults(func=cmd_setup)
    sub.add_parser('run').set_defaults(func=cmd_run)

    p_start = sub.add_parser('start')
    p_start.add_argument('--project', default=None)
    p_start.add_argument('--task', default=None)
    p_start.add_argument('--note', default='')
    p_start.set_defaults(func=cmd_start)

    sub.add_parser('pause').set_defaults(func=cmd_pause)
    sub.add_parser('resume').set_defaults(func=cmd_resume)
    sub.add_parser('stop').set_defaults(func=cmd_stop)
    sub.add_parser('status').set_defaults(func=cmd_status)

    args = parser.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
