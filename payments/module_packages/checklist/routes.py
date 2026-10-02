import csv
import io

from flask import Blueprint, render_template, redirect, url_for, flash, request, Response
from flask_login import login_required, current_user

from app.extensions import db
from app.core.events.bus import emit
from app.core.export.registry import register_exporter
from .models import ChecklistList, ChecklistTask
from .generator import generate_checklist

bp = Blueprint("checklist", __name__, url_prefix="/checklist", template_folder="templates")


@bp.route("/")
@login_required
def index():
    show_archived = request.args.get("archived") == "1"
    query = ChecklistList.query.filter_by(user_id=current_user.id, archived=show_archived)
    lists = query.order_by(ChecklistList.updated_at.desc()).all()
    return render_template("checklist/index.html", lists=lists, show_archived=show_archived)


@bp.route("/new", methods=["POST"])
@login_required
def new_list():
    name = request.form.get("name", "").strip() or "Untitled checklist"
    checklist = ChecklistList(user_id=current_user.id, name=name)
    db.session.add(checklist)
    db.session.commit()
    emit("checklist.created", checklist_id=checklist.id, user_id=current_user.id)
    return redirect(url_for("checklist.view_list", list_id=checklist.id))


@bp.route("/<list_id>")
@login_required
def view_list(list_id):
    checklist = ChecklistList.query.filter_by(id=list_id, user_id=current_user.id).first_or_404()
    sort = request.args.get("sort", "position")
    search = request.args.get("q", "").strip()

    query = checklist.tasks.filter(ChecklistTask.parent_task_id.is_(None))
    if search:
        query = query.filter(ChecklistTask.title.ilike(f"%{search}%"))
    if sort == "priority":
        order = db.case((ChecklistTask.priority == "high", 0), (ChecklistTask.priority == "medium", 1), else_=2)
        query = query.order_by(order)
    elif sort == "due_date":
        query = query.order_by(ChecklistTask.due_date.is_(None), ChecklistTask.due_date)
    else:
        query = query.order_by(ChecklistTask.position)

    tasks = query.all()
    return render_template("checklist/view_list.html", checklist=checklist, tasks=tasks, sort=sort, search=search)


@bp.route("/<list_id>/rename", methods=["POST"])
@login_required
def rename_list(list_id):
    checklist = ChecklistList.query.filter_by(id=list_id, user_id=current_user.id).first_or_404()
    checklist.name = request.form.get("name", checklist.name).strip() or checklist.name
    db.session.commit()
    return redirect(url_for("checklist.view_list", list_id=list_id))


@bp.route("/<list_id>/archive", methods=["POST"])
@login_required
def archive_list(list_id):
    checklist = ChecklistList.query.filter_by(id=list_id, user_id=current_user.id).first_or_404()
    checklist.archived = not checklist.archived
    db.session.commit()
    return redirect(url_for("checklist.index"))


@bp.route("/<list_id>/duplicate", methods=["POST"])
@login_required
def duplicate_list(list_id):
    checklist = ChecklistList.query.filter_by(id=list_id, user_id=current_user.id).first_or_404()
    copy = ChecklistList(user_id=current_user.id, name=f"{checklist.name} (copy)")
    db.session.add(copy)
    db.session.flush()
    for task in checklist.tasks.filter(ChecklistTask.parent_task_id.is_(None)).order_by(ChecklistTask.position):
        db.session.add(ChecklistTask(
            list_id=copy.id, title=task.title, notes=task.notes, category=task.category,
            priority=task.priority, due_date=task.due_date, estimated_minutes=task.estimated_minutes,
            position=task.position,
        ))
    db.session.commit()
    return redirect(url_for("checklist.view_list", list_id=copy.id))


@bp.route("/<list_id>/delete", methods=["POST"])
@login_required
def delete_list(list_id):
    checklist = ChecklistList.query.filter_by(id=list_id, user_id=current_user.id).first_or_404()
    db.session.delete(checklist)
    db.session.commit()
    return redirect(url_for("checklist.index"))


@bp.route("/<list_id>/tasks/new", methods=["POST"])
@login_required
def new_task(list_id):
    checklist = ChecklistList.query.filter_by(id=list_id, user_id=current_user.id).first_or_404()
    title = request.form.get("title", "").strip()
    if title:
        max_pos = db.session.query(db.func.max(ChecklistTask.position)).filter_by(list_id=list_id).scalar() or 0
        db.session.add(ChecklistTask(list_id=list_id, title=title, position=max_pos + 1,
                                      priority=request.form.get("priority", "medium")))
        db.session.commit()
    return redirect(url_for("checklist.view_list", list_id=list_id))


@bp.route("/tasks/<task_id>/subtask", methods=["POST"])
@login_required
def new_subtask(task_id):
    parent = ChecklistTask.query.get_or_404(task_id)
    title = request.form.get("title", "").strip()
    if title:
        db.session.add(ChecklistTask(list_id=parent.list_id, parent_task_id=parent.id, title=title))
        db.session.commit()
    return redirect(url_for("checklist.view_list", list_id=parent.list_id))


@bp.route("/tasks/<task_id>/toggle", methods=["POST"])
@login_required
def toggle_task(task_id):
    task = ChecklistTask.query.get_or_404(task_id)
    task.completed = not task.completed
    db.session.commit()
    if task.completed:
        emit("task.completed", task_id=task.id, user_id=current_user.id)
    return redirect(url_for("checklist.view_list", list_id=task.list_id))


@bp.route("/tasks/<task_id>/edit", methods=["POST"])
@login_required
def edit_task(task_id):
    task = ChecklistTask.query.get_or_404(task_id)
    task.title = request.form.get("title", task.title).strip() or task.title
    task.notes = request.form.get("notes", task.notes)
    task.priority = request.form.get("priority", task.priority)
    task.category = request.form.get("category", task.category)
    due = request.form.get("due_date")
    task.due_date = due or None
    est = request.form.get("estimated_minutes")
    task.estimated_minutes = int(est) if est and est.isdigit() else None
    db.session.commit()
    return redirect(url_for("checklist.view_list", list_id=task.list_id))


@bp.route("/tasks/<task_id>/delete", methods=["POST"])
@login_required
def delete_task(task_id):
    task = ChecklistTask.query.get_or_404(task_id)
    list_id = task.list_id
    db.session.delete(task)
    db.session.commit()
    return redirect(url_for("checklist.view_list", list_id=list_id))


@bp.route("/<list_id>/export.csv")
@login_required
def export_csv(list_id):
    checklist = ChecklistList.query.filter_by(id=list_id, user_id=current_user.id).first_or_404()
    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(["Title", "Category", "Priority", "Due date", "Estimated minutes", "Completed"])
    for task in checklist.tasks.order_by(ChecklistTask.position):
        writer.writerow([task.title, task.category, task.priority, task.due_date, task.estimated_minutes, task.completed])
    return Response(output.getvalue(), mimetype="text/csv",
                     headers={"Content-Disposition": f"attachment;filename={checklist.name}.csv"})


@bp.route("/generate", methods=["GET", "POST"])
@login_required
def generate():
    preview = None
    raw_text = ""
    if request.method == "POST":
        raw_text = request.form.get("raw_text", "")
        preview = generate_checklist(raw_text)
    return render_template("checklist/generate.html", preview=preview, raw_text=raw_text)


@bp.route("/generate/save", methods=["POST"])
@login_required
def generate_save():
    name = request.form.get("name", "Generated checklist").strip() or "Generated checklist"
    titles = request.form.getlist("task_title")
    categories = request.form.getlist("task_category")
    priorities = request.form.getlist("task_priority")
    minutes = request.form.getlist("task_minutes")

    checklist = ChecklistList(user_id=current_user.id, name=name)
    db.session.add(checklist)
    db.session.flush()

    for i, title in enumerate(titles):
        if not title.strip():
            continue
        db.session.add(ChecklistTask(
            list_id=checklist.id, title=title.strip(),
            category=categories[i] if i < len(categories) else None,
            priority=priorities[i] if i < len(priorities) else "medium",
            estimated_minutes=int(minutes[i]) if i < len(minutes) and minutes[i].isdigit() else None,
            position=i,
        ))
    db.session.commit()
    emit("checklist.created", checklist_id=checklist.id, user_id=current_user.id)
    flash(f"Generated checklist '{name}' with {len(titles)} tasks.", "success")
    return redirect(url_for("checklist.view_list", list_id=checklist.id))


# ---- Full-system export registration (Part 10) ----

def _export_checklist(user):
    lists = ChecklistList.query.filter_by(user_id=user.id).all()
    payload = []
    for lst in lists:
        payload.append({
            "id": lst.id, "name": lst.name, "archived": lst.archived,
            "created_at": lst.created_at.isoformat() if lst.created_at else None,
            "tasks": [
                {
                    "id": t.id, "title": t.title, "notes": t.notes, "category": t.category,
                    "priority": t.priority, "due_date": t.due_date.isoformat() if t.due_date else None,
                    "estimated_minutes": t.estimated_minutes, "completed": t.completed,
                }
                for t in lst.tasks
            ],
        })

    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(["list", "task", "category", "priority", "due_date", "estimated_minutes", "completed"])
    for lst in lists:
        for t in lst.tasks:
            writer.writerow([lst.name, t.title, t.category or "", t.priority,
                              t.due_date.isoformat() if t.due_date else "",
                              t.estimated_minutes or "", "yes" if t.completed else "no"])

    import json
    return {
        "checklist.json": (json.dumps(payload, indent=2, default=str), "application/json"),
        "checklist.csv": (buf.getvalue(), "text/csv"),
    }


register_exporter("checklist", "Checklist (lists & tasks)", _export_checklist)
