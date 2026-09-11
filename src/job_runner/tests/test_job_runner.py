"""Tests for EDGE v3's Nextflow tool definition.

The shared store, executor, and HTTP layer are covered by edge-core's
job_runner test suite; this file only exercises command construction.
"""

import os
import shlex
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from job_runner import REGISTRY  # noqa: E402
from edge_job_runner import RequestError  # noqa: E402


class NextflowToolTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.config = self.root / "nextflow.config"
        self.config.write_text("// config", encoding="utf-8")
        self.workflow = self.root / "main.nf"
        self.workflow.write_text("// workflow", encoding="utf-8")
        self.work_dir = self.root / "work"
        self.work_dir.mkdir()
        self.tool = REGISTRY.create("nextflow", [str(self.root)])

    def payload(self, **overrides):
        payload = {
            "configPath": str(self.config),
            "workflowPath": str(self.workflow),
            "workDir": str(self.work_dir),
            "nextflowLogPath": str(self.root / ".nextflow.log"),
            "logPath": str(self.root / "job-runner.log"),
            "donePath": str(self.root / ".job-runner.done"),
            "outputPath": str(self.root / "output"),
            "runName": "edge-project-1-abc",
            "executor": "local",
        }
        payload.update(overrides)
        return self.tool.validate_auxiliary_paths(payload)

    def test_the_tool_is_registered_as_nextflow(self):
        # Renamed from 'edgev3_nextflow': the runner is generic, and the
        # deployment names its service separately.
        self.assertEqual(REGISTRY.names, ["nextflow"])
        self.assertEqual(self.tool.name, "nextflow")

    def test_builds_an_argument_array_never_a_shell_string(self):
        with patch.dict(os.environ, {"NEXTFLOW_EXEC": "/opt/nextflow"}):
            command = self.tool.build_command(self.payload())
        self.assertEqual(command[0], "/opt/nextflow")
        self.assertIn("-C", command)
        self.assertIn(str(self.config), command)
        self.assertIn("run", command)
        self.assertIn(str(self.workflow), command)
        self.assertEqual(command[command.index("-name") + 1], "edge-project-1-abc")

    def test_a_profile_is_passed_as_its_own_argument(self):
        with patch.dict(os.environ, {"NEXTFLOW_EXEC": "nextflow"}):
            command = self.tool.build_command(self.payload(profile="local"))
        self.assertEqual(command[command.index("-profile") + 1], "local")

    def test_comma_separated_profiles_are_accepted(self):
        with patch.dict(os.environ, {"NEXTFLOW_EXEC": "nextflow"}):
            command = self.tool.build_command(self.payload(profile="test,local"))
        self.assertEqual(command[command.index("-profile") + 1], "test,local")

    def test_omitting_a_profile_omits_the_flag(self):
        with patch.dict(os.environ, {"NEXTFLOW_EXEC": "nextflow"}):
            command = self.tool.build_command(self.payload())
        self.assertNotIn("-profile", command)

    def test_rejects_an_injected_profile(self):
        with self.assertRaises(RequestError):
            self.tool.build_command(self.payload(profile="local; rm -rf /"))

    def test_rejects_an_unsupported_executor(self):
        with self.assertRaises(RequestError):
            self.tool.build_command(self.payload(executor="kubernetes"))

    def test_rejects_an_invalid_run_name(self):
        with self.assertRaises(RequestError):
            self.tool.build_command(self.payload(runName="bad name!"))

    def test_rejects_a_config_outside_the_allowed_roots(self):
        with self.assertRaises(RequestError):
            self.tool.build_command(self.payload(configPath="/etc/passwd"))

    def test_rejects_a_workflow_that_does_not_exist(self):
        with self.assertRaises(RequestError):
            self.tool.build_command(self.payload(workflowPath=str(self.root / "no.nf")))

    def test_requires_the_nextflow_work_and_log_paths(self):
        # Nextflow writes to both, so both must be inside the allowed roots.
        for key in ("workDir", "nextflowLogPath"):
            payload = self.payload()
            del payload[key]
            with self.assertRaises(RequestError):
                self.tool.validate_auxiliary_paths(payload)

    def test_local_execution_sets_the_nextflow_variables(self):
        environment = self.tool.build_environment(self.payload())
        self.assertEqual(environment["NXF_CACHE_DIR"], str(self.work_dir))
        self.assertEqual(
            environment["NXF_LOG_FILE"], str(self.root / ".nextflow.log")
        )

    def test_slurm_submission_is_wrapped_in_ssh(self):
        with patch.dict(
            os.environ,
            {
                "NEXTFLOW_SLURM_SSH": "ssh user@login",
                "NEXTFLOW_REMOTE_EXEC": "nextflow",
            },
        ):
            command = self.tool.build_command(self.payload(executor="slurm"))
        self.assertEqual(command[:2], ["ssh", "user@login"])
        # The remote side is one shell string, so every argument must be quoted.
        remote = command[-1]
        self.assertEqual(shlex.split(remote)[0], "env")
        self.assertIn(f"NXF_CACHE_DIR={self.work_dir}", remote)
        self.assertIn("nextflow", remote)
        self.assertIn("edge-project-1-abc", remote)

    def test_slurm_uses_the_remote_executable(self):
        with patch.dict(
            os.environ,
            {
                "NEXTFLOW_SLURM_SSH": "ssh user@login",
                "NEXTFLOW_REMOTE_EXEC": "/remote/bin/nextflow",
                "NEXTFLOW_EXEC": "/local/bin/nextflow",
            },
        ):
            command = self.tool.build_command(self.payload(executor="slurm"))
        self.assertIn("/remote/bin/nextflow", command[-1])
        self.assertNotIn("/local/bin/nextflow", command[-1])

    def test_local_execution_ignores_the_slurm_ssh_setting(self):
        # Configuring slurm credentials must not affect a local submission.
        with patch.dict(
            os.environ,
            {"NEXTFLOW_SLURM_SSH": "ssh user@login", "NEXTFLOW_EXEC": "nextflow"},
        ):
            command = self.tool.build_command(self.payload(executor="local"))
        self.assertEqual(command[0], "nextflow")

    def test_rejects_an_ssh_setting_that_is_not_ssh(self):
        with patch.dict(os.environ, {"NEXTFLOW_SLURM_SSH": "curl evil.example"}):
            with self.assertRaises(RequestError):
                self.tool.build_command(self.payload(executor="slurm"))

    def test_rejects_an_unparsable_ssh_setting(self):
        with patch.dict(os.environ, {"NEXTFLOW_SLURM_SSH": 'ssh "unclosed'}):
            with self.assertRaises(RequestError):
                self.tool.build_command(self.payload(executor="slurm"))

    def test_rejects_an_empty_executable(self):
        with patch.dict(os.environ, {"NEXTFLOW_EXEC": "   "}):
            with self.assertRaises(RequestError):
                self.tool.build_command(self.payload())

    def test_ignores_payload_keys_it_does_not_use(self):
        # edge-core sends a superset payload so one webapp serves both apps.
        with patch.dict(os.environ, {"NEXTFLOW_EXEC": "nextflow"}):
            command = self.tool.build_command(
                self.payload(workPath=str(self.work_dir), resume=False, paramsPath=None)
            )
        self.assertEqual(command[0], "nextflow")


if __name__ == "__main__":
    unittest.main()
