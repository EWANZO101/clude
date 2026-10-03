import csv
import io
from datetime import datetime, timedelta, date
from functools import wraps
from flask import Blueprint, render_template, request, abort, Response, send_file
from flask_login import login_required, current_user
from app.models.user import User
from app.models.project import Project, Task, Client
from app.models.time_entry import TimeEntry

reports_bp = Blueprint('reports', __name__, url_prefix='/reports')

REPORT_TYPES = {
    'time': 'Time Spent Report',
    'employee': 'Employee Report',
    'project': 'Project Report',
    'task': 'Task Report',
    'client': 'Client / Billable Report',
}


def manager_required(f):
    @wraps(f)
    def wrapped(*args, **kwargs):
        if not current_user.is_manager:
            abort(403)
        return f(*args, **kwargs)
    return wrapped


def _parse_date(s, default):
    if not s:
        return default
    try:
        return datetime.strptime(s, '%Y-%m-%d').date()
    except ValueError:
        return default


def _get_filtered_entries(args):
    today = date.today()
    range_start = _parse_date(args.get('start'), today - timedelta(days=6))
    range_end = _parse_date(args.get('end'), today)

    query = TimeEntry.query.join(User, TimeEntry.user_id == User.id).filter(
        User.team_id == current_user.team_id,
        TimeEntry.started_at >= datetime.combine(range_start, datetime.min.time()),
        TimeEntry.started_at < datetime.combine(range_end + timedelta(days=1), datetime.min.time()),
        TimeEntry.status == 'stopped',
    )

    user_id = args.get('user_id')
    project_id = args.get('project_id')
    task_id = args.get('task_id')

    if user_id:
        query = query.filter(TimeEntry.user_id == int(user_id))
    if project_id:
        query = query.filter(TimeEntry.project_id == int(project_id))
    if task_id:
        query = query.filter(TimeEntry.task_id == int(task_id))

    return query.order_by(TimeEntry.started_at.asc()).all(), range_start, range_end


def _build_rows(report_type, entries):
    """Returns (headers, rows) as lists of strings, shaped per report type."""
    if report_type == 'employee':
        totals = {}
        for e in entries:
            totals.setdefault(e.user.name, 0)
            totals[e.user.name] += e.duration_seconds()
        headers = ['Employee', 'Total Time (h:m:s)', 'Total Hours']
        rows = [[name, _hms(secs), f'{secs/3600:.2f}'] for name, secs in sorted(totals.items(), key=lambda x: -x[1])]
        return headers, rows

    if report_type == 'project':
        totals = {}
        for e in entries:
            name = e.project.name if e.project else 'No project'
            totals.setdefault(name, 0)
            totals[name] += e.duration_seconds()
        headers = ['Project', 'Total Time (h:m:s)', 'Total Hours']
        rows = [[name, _hms(secs), f'{secs/3600:.2f}'] for name, secs in sorted(totals.items(), key=lambda x: -x[1])]
        return headers, rows

    if report_type == 'task':
        totals = {}
        for e in entries:
            name = e.task.name if e.task else 'No task'
            totals.setdefault(name, 0)
            totals[name] += e.duration_seconds()
        headers = ['Task', 'Total Time (h:m:s)', 'Total Hours']
        rows = [[name, _hms(secs), f'{secs/3600:.2f}'] for name, secs in sorted(totals.items(), key=lambda x: -x[1])]
        return headers, rows

    if report_type == 'client':
        totals = {}
        for e in entries:
            if not e.is_billable:
                continue
            client = e.project.client if e.project else None
            name = client.name if client else 'No client'
            rate = e.project.effective_rate() if e.project else None
            secs = e.duration_seconds()
            key = name
            if key not in totals:
                totals[key] = {'seconds': 0, 'amount': 0.0}
            totals[key]['seconds'] += secs
            if rate:
                totals[key]['amount'] += (secs / 3600.0) * rate
        headers = ['Client', 'Billable Time (h:m:s)', 'Billable Hours', 'Amount']
        rows = [
            [name, _hms(d['seconds']), f"{d['seconds']/3600:.2f}", f"{d['amount']:.2f}" if d['amount'] else '—']
            for name, d in sorted(totals.items(), key=lambda x: -x[1]['seconds'])
        ]
        return headers, rows

    # default: 'time' - raw entry list
    headers = ['Date', 'Employee', 'Project', 'Task', 'Note', 'Duration']
    rows = [
        [
            e.started_at.strftime('%Y-%m-%d %H:%M'),
            e.user.name,
            e.project.name if e.project else '—',
            e.task.name if e.task else '—',
            e.note or '',
            e.duration_hms(),
        ]
        for e in entries
    ]
    return headers, rows


def _hms(seconds):
    h, rem = divmod(int(seconds), 3600)
    m, s = divmod(rem, 60)
    return f'{h:02d}:{m:02d}:{s:02d}'


@reports_bp.route('/')
@login_required
@manager_required
def index():
    report_type = request.args.get('type', 'time')
    if report_type not in REPORT_TYPES:
        report_type = 'time'

    entries, range_start, range_end = _get_filtered_entries(request.args)
    headers, rows = _build_rows(report_type, entries)

    members = User.query.filter_by(team_id=current_user.team_id).all()
    projects = Project.query.filter_by(team_id=current_user.team_id).all()
    tasks = Task.query.join(Project).filter(Project.team_id == current_user.team_id).all()

    return render_template(
        'reports/index.html',
        report_types=REPORT_TYPES,
        report_type=report_type,
        headers=headers,
        rows=rows,
        range_start=range_start,
        range_end=range_end,
        members=members,
        projects=projects,
        tasks=tasks,
        filter_user_id=request.args.get('user_id'),
        filter_project_id=request.args.get('project_id'),
        filter_task_id=request.args.get('task_id'),
    )


@reports_bp.route('/export/csv')
@login_required
@manager_required
def export_csv():
    report_type = request.args.get('type', 'time')
    if report_type not in REPORT_TYPES:
        report_type = 'time'

    entries, range_start, range_end = _get_filtered_entries(request.args)
    headers, rows = _build_rows(report_type, entries)

    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(headers)
    writer.writerows(rows)

    filename = f'teamtreck_{report_type}_{range_start}_{range_end}.csv'
    return Response(
        buf.getvalue(),
        mimetype='text/csv',
        headers={'Content-Disposition': f'attachment; filename={filename}'},
    )


@reports_bp.route('/export/pdf')
@login_required
@manager_required
def export_pdf():
    from reportlab.lib.pagesizes import letter
    from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle
    from reportlab.lib.styles import getSampleStyleSheet
    from reportlab.lib import colors

    report_type = request.args.get('type', 'time')
    if report_type not in REPORT_TYPES:
        report_type = 'time'

    entries, range_start, range_end = _get_filtered_entries(request.args)
    headers, rows = _build_rows(report_type, entries)

    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=letter)
    styles = getSampleStyleSheet()
    story = []

    story.append(Paragraph(REPORT_TYPES[report_type], styles['Title']))
    story.append(Paragraph(f'{range_start} to {range_end}', styles['Normal']))
    story.append(Spacer(1, 16))

    table_data = [headers] + rows if rows else [headers, ['No data in this range' if not rows else '']]
    table = Table(table_data, repeatRows=1)
    table.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, 0), colors.HexColor('#4f46e5')),
        ('TEXTCOLOR', (0, 0), (-1, 0), colors.white),
        ('FONTSIZE', (0, 0), (-1, -1), 8),
        ('GRID', (0, 0), (-1, -1), 0.5, colors.HexColor('#e5e7eb')),
        ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.white, colors.HexColor('#f9fafb')]),
        ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
        ('TOPPADDING', (0, 0), (-1, -1), 5),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 5),
    ]))
    story.append(table)

    doc.build(story)
    buf.seek(0)

    filename = f'teamtreck_{report_type}_{range_start}_{range_end}.pdf'
    return send_file(buf, mimetype='application/pdf', as_attachment=True, download_name=filename)
