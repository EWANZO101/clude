from flask_login import LoginManager
from flask_socketio import SocketIO
from flask_wtf import CSRFProtect

login_manager = LoginManager()
socketio = SocketIO()
csrf = CSRFProtect()
