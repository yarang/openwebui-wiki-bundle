"""Shared definitions for spark-switch controller and its backends.

This module has no dependencies on the other spark_* modules, so both
spark_backend_docker and spark_backend_kube can import from it without
creating a cycle (spark_switch imports the backends, never the other way
round). All files sit side by side in /app inside the container and next to
each other on sys.path in the tests.
"""

from __future__ import annotations

from dataclasses import dataclass

# Labels the Docker backend stamps on the container it creates. Kept here so
# both the controller (re-exported) and the Docker backend agree on them.
LABEL_PROFILE = "dev.guardian.spark-switch.profile"
LABEL_MANAGED = "dev.guardian.spark-switch.managed"

MAX_ERROR_CHARS = 4000


class ConfigError(Exception):
    pass


class ProfileError(Exception):
    pass


class SwitchFailure(Exception):
    pass


@dataclass
class Observed:
    """What a backend sees deployed right now.

    state:
      "running"  - the serving workload is up (readiness is still decided by
                   the controller's /v1/models probe, not by this)
      "pending"  - created but not running yet (rollout / container starting)
      "failed"   - the workload died (exited, crash loop, pod Failed, ...)
      "absent"   - nothing is deployed (no container / no deployment)
      "unknown"  - the backend could not tell (API error, bad JSON)
    profile: the profile name the workload was last told to serve, or None
    when it cannot be mapped to a known profile.
    """

    profile: str = None          # type: str | None
    state: str = "unknown"
    detail: str = ""
    # Kube-only extras (default None so Docker-backend constructor calls and
    # every pre-existing Observed(...) keeps working):
    #   requested  - the template's spark-switch/requested-at value of the
    #                rollout this observation describes (None when absent)
    #   generation - metadata.generation of the workload object
    # inspect() fills them so the controller can hand the adopted attempt
    # (and its generation) to commit_adoption(); inspect() itself never
    # writes backend bookkeeping.
    requested: str = None         # type: str | None
    generation: int = None        # type: int | None
