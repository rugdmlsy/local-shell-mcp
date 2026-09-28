from __future__ import annotations

import ast
import functools
import gzip
import importlib.machinery
import importlib.metadata as importlib_metadata
import io
import os
import re
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path

_MAX_DEPENDENCY_DISCOVERY_ITERATIONS = 16
_MISSING_MODULE_PATTERN = re.compile(r"ModuleNotFoundError: No module named ['\"]([^'\"]+)")
_NATIVE_SUFFIXES = (".so", ".pyd", ".dylib", *importlib.machinery.EXTENSION_SUFFIXES)


@dataclass(frozen=True)
class WorkerBundleArtifact:
    payload: bytes
    distributions: tuple[str, ...]


def _canonical_dist_name(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def _dist_name_from_requirement(requirement: str) -> str | None:
    # Extras are opt-in capabilities, not startup requirements. Pulling them in
    # would make the worker closure depend on whichever extras the controller used.
    if re.search(r"\bextra\s*==", requirement):
        return None
    match = re.match(r"\s*([A-Za-z0-9_.-]+)", requirement)
    return match.group(1) if match else None


def _distribution_name(distribution: importlib_metadata.Distribution, fallback: str) -> str:
    return str(distribution.metadata.get("Name") or fallback)


def _distribution_has_native_extensions(distribution: importlib_metadata.Distribution) -> str | None:
    for entry in sorted(distribution.files or [], key=lambda item: str(item)):
        name = str(entry).lower()
        if any(name.endswith(suffix.lower()) for suffix in _NATIVE_SUFFIXES):
            return str(entry)
    return None


def _resolve_distribution_closure(initial: set[str]) -> tuple[tuple[str, ...], dict[str, object]]:
    pending = sorted(initial, key=_canonical_dist_name)
    resolved: dict[str, object] = {}
    display_names: dict[str, str] = {}
    while pending:
        requested = pending.pop(0)
        canonical = _canonical_dist_name(requested)
        if canonical in resolved:
            continue
        try:
            distribution = importlib_metadata.distribution(requested)
        except importlib_metadata.PackageNotFoundError as exc:
            raise RuntimeError(
                f"worker dependency distribution {requested!r} is not installed on the controller"
            ) from exc
        native_entry = _distribution_has_native_extensions(distribution)
        if native_entry:
            raise RuntimeError(
                "refusing to vendor worker dependency "
                f"{_distribution_name(distribution, requested)!r}: native extension "
                f"{native_entry!r} cannot be used safely across worker platforms/ABIs"
            )
        resolved[canonical] = distribution
        display_names[canonical] = _distribution_name(distribution, requested)
        required = {
            name
            for requirement in distribution.requires or []
            if (name := _dist_name_from_requirement(requirement)) is not None
        }
        pending.extend(
            sorted(
                (name for name in required if _canonical_dist_name(name) not in resolved),
                key=_canonical_dist_name,
            )
        )
        pending.sort(key=_canonical_dist_name)
    names = tuple(display_names[key] for key in sorted(display_names))
    return names, resolved


def _normalized_tar_info(info: tarfile.TarInfo) -> tarfile.TarInfo:
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    info.pax_headers = {}
    return info


def _add_distribution_files(
    tar: tarfile.TarFile,
    distribution: object,
    added_names: set[str],
) -> None:
    for entry in sorted(distribution.files or [], key=lambda item: str(item)):
        entry_path = Path(entry)
        if entry_path.is_absolute() or ".." in entry_path.parts:
            continue
        source = Path(distribution.locate_file(entry))
        if not source.is_file() or source.suffix in {".pyc", ".pyo"}:
            continue
        archive_name = str(Path("vendor") / entry_path)
        if archive_name in added_names:
            continue
        tar.add(source, arcname=archive_name, filter=_normalized_tar_info)
        added_names.add(archive_name)


def _create_bundle(distributions: set[str]) -> WorkerBundleArtifact:
    names, resolved = _resolve_distribution_closure(distributions)
    package_root = Path(__file__).resolve().parent
    buffer = io.BytesIO()
    with (
        gzip.GzipFile(fileobj=buffer, mode="wb", filename="", mtime=0) as compressed,
        tarfile.open(fileobj=compressed, mode="w") as tar,
    ):
        for path in sorted(package_root.rglob("*")):
            if not path.is_file():
                continue
            relative = path.relative_to(package_root)
            is_helper = relative.parts[:1] == ("helpers",) and path.name in {
                "tmux",
                "tmux.LICENSE",
            }
            if path.suffix == ".py" or is_helper:
                tar.add(
                    path,
                    arcname=str(path.relative_to(package_root.parent)),
                    filter=_normalized_tar_info,
                )
        added_names: set[str] = set()
        for canonical in sorted(resolved):
            _add_distribution_files(tar, resolved[canonical], added_names)
    return WorkerBundleArtifact(buffer.getvalue(), names)


def _extract_candidate(payload: bytes, destination: Path) -> None:
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        archive.extractall(destination)  # noqa: S202 - bundle was created locally by this module.


def _self_test_environment(runtime: Path) -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if key not in {"PYTHONHOME", "PYTHONPATH", "PYTHONUSERBASE"}
        and not key.startswith("LOCAL_SHELL_MCP_")
    }
    environment["PYTHONNOUSERSITE"] = "1"
    environment["PYTHONPATH"] = os.pathsep.join((str(runtime), str(runtime / "vendor")))
    environment["LOCAL_SHELL_MCP_WORKSPACE_ROOT"] = str(runtime / "workspace")
    environment["LOCAL_SHELL_MCP_STATE_DIR"] = str(runtime / "state")
    environment["LOCAL_SHELL_MCP_WORKER_STATE_DIR"] = str(runtime / "worker-state")
    return environment


def _run_isolated_worker_self_test(runtime: Path) -> subprocess.CompletedProcess[str]:
    environment = _self_test_environment(runtime)
    commands = (
        [sys.executable, "-S", "-m", "local_shell_mcp.main", "worker", "--help"],
        [
            sys.executable,
            "-S",
            "-c",
            (
                "from local_shell_mcp.remote_worker_cli import _worker_payload; "
                "payload=_worker_payload(None, '.', 'self-test'); "
                "assert payload['invite']=='self-test'; "
                "assert 'shell' in payload['capabilities']; "
                "assert isinstance(payload['info'], dict)"
            ),
        ],
    )
    for command in commands:
        completed = subprocess.run(  # noqa: S603
            command,
            cwd=runtime,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
        if completed.returncode:
            return completed
    return completed


def verify_extracted_worker_runtime(runtime: Path) -> None:
    completed = _run_isolated_worker_self_test(runtime)
    if completed.returncode:
        detail = (completed.stderr or completed.stdout).strip()
        raise RuntimeError(f"isolated worker startup self-test failed:\n{detail}")


def _missing_module_from_failure(completed: subprocess.CompletedProcess[str]) -> str | None:
    match = _MISSING_MODULE_PATTERN.search("\n".join((completed.stderr, completed.stdout)))
    return match.group(1).split(".", 1)[0] if match else None


def _distribution_for_module(module: str) -> str:
    mapping = importlib_metadata.packages_distributions()
    candidates = sorted(set(mapping.get(module, [])), key=_canonical_dist_name)
    if not candidates:
        raise RuntimeError(
            "isolated worker startup is missing external module "
            f"{module!r}, but importlib.metadata cannot map it to an installed distribution"
        )
    return candidates[0]


def _optional_import_try(statement: ast.Try) -> bool:
    """Return whether a module-level try explicitly tolerates missing imports."""
    tolerated = {"ImportError", "ModuleNotFoundError", "Exception", "BaseException"}
    for handler in statement.handlers:
        if handler.type is None:
            return True
        if isinstance(handler.type, ast.Name) and handler.type.id in tolerated:
            return True
        if isinstance(handler.type, ast.Tuple) and any(
            isinstance(item, ast.Name) and item.id in tolerated for item in handler.type.elts
        ):
            return True
    return False


def _resolve_local_import(current: str, level: int, module: str | None) -> str:
    package = ["local_shell_mcp", *current.split(".")[:-1]]
    if level > 1:
        trim = level - 1
        package = package[:-trim] if trim <= len(package) else []
    if module:
        package.extend(module.split("."))
    return ".".join(package)


def _worker_startup_external_modules(
    package_root: Path | None = None,
    roots: tuple[str, ...] = ("remote_worker_cli",),
) -> set[str]:
    """Conservatively find required module-level imports reachable at worker startup.

    Dynamic isolated startup testing catches imports exercised on the build host.
    This static seed also walks both sides of module-level conditionals, so an
    unguarded dependency used only on another worker OS is still vendored (or
    rejected) before release. Imports inside functions/classes are capabilities,
    not startup dependencies. Imports protected by a try that tolerates import
    failure remain optional and are not forced into the worker bundle.
    """
    package_root = package_root or Path(__file__).resolve().parent
    stdlib = set(sys.stdlib_module_names) | {"__future__"}
    pending = list(roots)
    visited: set[str] = set()
    external: set[str] = set()

    def visit_statements(statements: list[ast.stmt], *, optional: bool = False) -> None:
        for statement in statements:
            if isinstance(statement, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                continue
            if isinstance(statement, ast.Try):
                guarded = optional or _optional_import_try(statement)
                visit_statements(statement.body, optional=guarded)
                visit_statements(statement.orelse, optional=optional)
                visit_statements(statement.finalbody, optional=optional)
                continue
            if isinstance(statement, ast.If):
                # TYPE_CHECKING-only imports do not execute at worker startup.
                if isinstance(statement.test, ast.Name) and statement.test.id == "TYPE_CHECKING":
                    visit_statements(statement.orelse, optional=optional)
                    continue
                visit_statements(statement.body, optional=optional)
                visit_statements(statement.orelse, optional=optional)
                continue
            if isinstance(statement, (ast.With, ast.AsyncWith)):
                visit_statements(statement.body, optional=optional)
                continue
            if optional:
                continue
            if isinstance(statement, ast.Import):
                for alias in statement.names:
                    if alias.name.startswith("local_shell_mcp."):
                        pending.append(alias.name.removeprefix("local_shell_mcp."))
                    else:
                        top_level = alias.name.split(".", 1)[0]
                        if top_level not in stdlib:
                            external.add(top_level)
                continue
            if not isinstance(statement, ast.ImportFrom):
                continue
            if statement.level:
                target = _resolve_local_import(
                    current_module,
                    statement.level,
                    statement.module,
                )
                if target == "local_shell_mcp":
                    for alias in statement.names:
                        if alias.name != "*":
                            pending.append(alias.name)
                elif target.startswith("local_shell_mcp."):
                    pending.append(target.removeprefix("local_shell_mcp."))
                continue
            if not statement.module:
                continue
            if statement.module.startswith("local_shell_mcp."):
                pending.append(statement.module.removeprefix("local_shell_mcp."))
            else:
                top_level = statement.module.split(".", 1)[0]
                if top_level not in stdlib:
                    external.add(top_level)

    while pending:
        current_module = pending.pop(0)
        if not current_module or current_module in visited:
            continue
        visited.add(current_module)
        source = package_root.joinpath(*current_module.split(".")).with_suffix(".py")
        if not source.is_file():
            continue
        tree = ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
        visit_statements(tree.body)

    return external


def _startup_distribution_roots() -> set[str]:
    return {_distribution_for_module(module) for module in _worker_startup_external_modules()}


@functools.lru_cache(maxsize=1)
def worker_bundle_artifact() -> WorkerBundleArtifact:
    requested: set[str] = _startup_distribution_roots()
    for _attempt in range(_MAX_DEPENDENCY_DISCOVERY_ITERATIONS):
        artifact = _create_bundle(requested)
        with tempfile.TemporaryDirectory(prefix="worker-bundle-verify-") as temporary:
            runtime = Path(temporary) / "runtime"
            runtime.mkdir()
            _extract_candidate(artifact.payload, runtime)
            completed = _run_isolated_worker_self_test(runtime)
        if completed.returncode == 0:
            return artifact
        missing_module = _missing_module_from_failure(completed)
        if not missing_module:
            detail = (completed.stderr or completed.stdout).strip()
            raise RuntimeError(f"isolated worker startup self-test failed:\n{detail}")
        distribution = _distribution_for_module(missing_module)
        if _canonical_dist_name(distribution) in {
            _canonical_dist_name(item) for item in requested
        }:
            detail = (completed.stderr or completed.stdout).strip()
            raise RuntimeError(
                f"worker bundle still cannot import {missing_module!r} after vendoring "
                f"{distribution!r}:\n{detail}"
            )
        requested.add(distribution)
    raise RuntimeError(
        "worker dependency discovery exceeded "
        f"{_MAX_DEPENDENCY_DISCOVERY_ITERATIONS} iterations"
    )


def verify_worker_bundle() -> dict[str, object]:
    artifact = worker_bundle_artifact()
    with tempfile.TemporaryDirectory(prefix="worker-bundle-release-verify-") as temporary:
        runtime = Path(temporary) / "runtime"
        runtime.mkdir()
        _extract_candidate(artifact.payload, runtime)
        verify_extracted_worker_runtime(runtime)
    return {
        "size": len(artifact.payload),
        "vendored_distributions": list(artifact.distributions),
    }
