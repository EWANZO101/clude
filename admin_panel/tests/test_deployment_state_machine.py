"""
Regression test for the bug fixed in this pass: agent/update_manager.py's
automatic-rollback flow reports "rolling_back" immediately after a failed
"health_check", but app/models.py::ALLOWED_TRANSITIONS did not allow that
transition — every rollback status report was silently rejected (409) by
app/blueprints/agent_api.py::report_update_status, leaving real deployments
stuck showing "Health Check" forever even after the instance had actually
recovered (see the two real deployments this happened to: public_id
f028c701-306f-4c73-888a-0e030066243d and 1e23dfc9-d8b2-4959-9d81-e5f5a2a3f74c
in admin_panel.db, both logged as 409 in app.log at 20:17:14 / 20:17:28 on
2026-09-08).

This test hard-codes every real status sequence agent/update_manager.py can
produce (traced directly from its source — see the comments on each case)
and asserts every consecutive pair is a legal transition in
app/models.py::ALLOWED_TRANSITIONS. It is intentionally NOT a copy of the
transition table itself — it must fail the way it failed for real if
"rolling_back" (or any other agent-reported status) is ever again reachable
in a state ALLOWED_TRANSITIONS doesn't expect.

Run directly:
    python3 -m unittest tests.test_deployment_state_machine -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.models import ALLOWED_TRANSITIONS


def assert_sequence_legal(case, sequence):
    for i in range(len(sequence) - 1):
        current, nxt = sequence[i], sequence[i + 1]
        allowed = ALLOWED_TRANSITIONS.get(current, set())
        if nxt not in allowed:
            raise AssertionError(
                f"[{case}] transition '{current}' -> '{nxt}' is not in "
                f"ALLOWED_TRANSITIONS[{current!r}] = {sorted(allowed)}"
            )


class TestDeploymentStateMachine(unittest.TestCase):
    # "waiting" -> "downloading" happens server-side, inside the download
    # endpoint itself (agent_api.py:291-292), the moment the Agent starts
    # streaming the package — not reported by update_manager.py.

    def test_full_success_path(self):
        # run_update_cycle(): validating -> preparing -> installing ->
        # restarting -> health_check -> successful.
        assert_sequence_legal("success", [
            "scheduled", "waiting", "downloading", "validating", "preparing",
            "installing", "restarting", "health_check", "successful",
        ])

    def test_failure_at_every_pre_health_check_stage(self):
        # Every early-exit "failed" report in run_update_cycle().
        prior_states = ["downloading", "validating", "preparing", "installing", "restarting"]
        for prior in prior_states:
            assert_sequence_legal(f"failure after {prior}", [prior, "failed"])

    def test_automatic_rollback_succeeds(self):
        # _attempt_rollback(): health_check fails -> rolling_back -> rolled_back.
        assert_sequence_legal("rollback succeeds", [
            "restarting", "health_check", "rolling_back", "rolled_back",
        ])

    def test_automatic_rollback_itself_fails(self):
        # _attempt_rollback(): restore_recovery_point raises, or the restored
        # version also fails its health check -> reports "failed" instead.
        assert_sequence_legal("rollback fails", [
            "restarting", "health_check", "rolling_back", "failed",
        ])

    def test_first_ever_install_has_nothing_to_roll_back_to(self):
        # _attempt_rollback(): meta["had_app"] is False -> _clear_kiosk_configuration
        # -> reports "failed" directly (no restart/re-check possible).
        assert_sequence_legal("first-install rollback", [
            "restarting", "health_check", "rolling_back", "failed",
        ])

    def test_every_agent_reported_status_is_a_real_status(self):
        from app.models import DEPLOYMENT_STATUSES
        agent_reported = {
            "validating", "preparing", "installing", "restarting",
            "health_check", "successful", "failed", "rolling_back", "rolled_back",
        }
        unknown = agent_reported - set(DEPLOYMENT_STATUSES)
        self.assertFalse(unknown, f"Agent can report statuses the Admin Panel doesn't know: {unknown}")


if __name__ == "__main__":
    unittest.main()
