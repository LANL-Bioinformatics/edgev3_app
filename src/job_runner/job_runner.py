#!/usr/bin/env python3
"""EDGE v3 job runner.

Defines the tool this application executes and delegates everything else --
durable state, process supervision, and the HTTP API -- to the shared
``edge_job_runner`` library that ships with edge-core.
"""

from __future__ import annotations

import os
import re
import shlex
import sys
from pathlib import Path
from typing import Any

# The library lives beside the webapp in the edge-core submodule.
_LIBRARY_PATH = Path(
    os.environ.get(
        "EDGE_JOB_RUNNER_LIB",
        str(Path(__file__).resolve().parents[1] / "edge-v3" / "job_runner"),
    )
)
if str(_LIBRARY_PATH) not in sys.path:
    sys.path.insert(0, str(_LIBRARY_PATH))

from edge_job_runner import (  # noqa: E402 - path set up above
    RequestError,
    ToolDefinition,
    ToolRegistry,
    cli,
)
from edge_job_runner.tooling import JOB_ID_PATTERN  # noqa: E402

# One or more comma-separated nextflow profile names.
NEXTFLOW_PROFILE_PATTERN = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}(?:,[A-Za-z0-9][A-Za-z0-9_.-]{0,63})*$"
)


class NextflowTool(ToolDefinition):
    """Runs a Nextflow workflow, optionally submitting it through slurm.

    The webapp sends paths and flags rather than a command line, so this class
    owns assembling the ``nextflow run`` invocation.
    """

    name = "nextflow"
    # The workflow's own log and cache directories must also be inside the
    # allowed roots, since nextflow writes to both.
    required_paths = ("logPath", "donePath", "workDir", "nextflowLogPath")

    def build_command(self, payload: dict[str, Any]) -> list[str]:
        config_path = self.path(payload, "configPath", must_exist=True)
        workflow_path = self.path(payload, "workflowPath", must_exist=True)

        executor = payload.get("executor", "local")
        if not isinstance(executor, str) or executor not in {"local", "slurm"}:
            raise RequestError("input.executor must be 'local' or 'slurm'")

        run_name = payload.get("runName")
        if not isinstance(run_name, str) or not JOB_ID_PATTERN.fullmatch(run_name):
            raise RequestError("input.runName is invalid")

        # Only reach for slurm credentials when slurm was actually requested.
        ssh_command = (
            os.environ.get("NEXTFLOW_SLURM_SSH", "").strip()
            if executor == "slurm"
            else ""
        )
        # A remote nextflow lives on the login node, so its path may differ.
        executable = self.executable(
            "NEXTFLOW_REMOTE_EXEC" if ssh_command else "NEXTFLOW_EXEC", "nextflow"
        )

        command = [
            executable,
            "-C",
            config_path,
            "-q",
            "run",
            workflow_path,
            "-name",
            run_name,
        ]
        profile = payload.get("profile")
        if profile is not None:
            if not isinstance(profile, str) or not NEXTFLOW_PROFILE_PATTERN.fullmatch(
                profile
            ):
                raise RequestError("input.profile is invalid")
            command.extend(["-profile", profile])

        if ssh_command:
            return self._wrap_in_ssh(ssh_command, command, payload)
        return command

    @staticmethod
    def _wrap_in_ssh(
        ssh_command: str, command: list[str], payload: dict[str, Any]
    ) -> list[str]:
        """Wrap the invocation in an ssh hop to the scheduler login node.

        The remote side is a single shell string, so every argument is quoted
        with :func:`shlex.join`. The nextflow variables are passed through
        ``env`` because the remote shell does not inherit our environment.
        """
        try:
            ssh_argv = shlex.split(ssh_command)
        except ValueError as error:
            raise RequestError(f"NEXTFLOW_SLURM_SSH is invalid: {error}") from error
        # Guard against NEXTFLOW_SLURM_SSH being pointed at an arbitrary binary.
        if not ssh_argv or Path(ssh_argv[0]).name != "ssh":
            raise RequestError("NEXTFLOW_SLURM_SSH must start with ssh")
        remote_command = [
            "env",
            f"NXF_CACHE_DIR={payload['workDir']}",
            f"NXF_LOG_FILE={payload['nextflowLogPath']}",
            *command,
        ]
        return [*ssh_argv, shlex.join(remote_command)]

    def build_environment(self, payload: dict[str, Any]) -> dict[str, str]:
        """Point nextflow at the project's cache and log locations.

        Only relevant for local execution; the slurm path passes these through
        ``env`` on the remote command instead.
        """
        environment = os.environ.copy()
        environment["NXF_CACHE_DIR"] = payload["workDir"]
        environment["NXF_LOG_FILE"] = payload["nextflowLogPath"]
        return environment


REGISTRY = ToolRegistry(NextflowTool)


def main() -> None:
    cli.run(
        REGISTRY,
        default_state_db="/edgev3/io/job_runner/jobs.sqlite3",
        default_allowed_roots="/edgev3/io",
    )


if __name__ == "__main__":
    main()
