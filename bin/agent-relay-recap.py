#!/usr/bin/env python3
"""Collect allowlist-scoped work activity for `agent-relay recap` and `!bot recap`.

Sources (strictly filtered to `recap.github_orgs`; personal repos are never included):
  1. GitHub (`gh`): merged PRs authored by @me since the lookback window + open PRs (CI & review state)
  2. Local Git: dirty working trees, unpushed commits, and active branches for repos whose remote matches `recap.github_orgs`
  3. Local Langfuse (optional): recent agent sessions whose repo matches `recap.github_orgs`

Stdlib only; Python 3.8+.
"""
import argparse
import base64
import concurrent.futures
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


class RecapError(Exception):
    pass


GITHUB_REMOTE_RE = re.compile(
    r"^(?:(?:https?|ssh)://(?:[^@/\s]+@)?|git@)github\.com[:/](?P<org>[A-Za-z0-9_.-]+)/(?P<repo>[A-Za-z0-9_.-]+?)(?:\.git)?/?$",
    re.IGNORECASE,
)
GITHUB_SLUG_RE = re.compile(
    r"(?:github\.com[:/])?(?P<org>[A-Za-z0-9][A-Za-z0-9-]*)/(?P<repo>[A-Za-z0-9_.-]+)"
)
DURATION_RE = re.compile(r"^(?P<num>\d+)(?P<unit>[dhw])$", re.IGNORECASE)


def local_now(now_str=None):
    if now_str:
        parsed = parse_iso(now_str)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.datetime.now().astimezone().tzinfo)
        return parsed
    return dt.datetime.now().astimezone()


def parse_iso(value):
    text = (value or "").strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    return dt.datetime.fromisoformat(text)


def resolve_since(spec, now=None):
    """Resolve a lookback spec into (since_dt, human_label).

    On Mondays, default / 'yesterday' reaches back to Friday 00:00 local time.
    """
    ref = now if now is not None else local_now()
    raw = (spec or "").strip()
    lower = raw.lower()

    if not raw or lower == "yesterday":
        days_back = 3 if ref.weekday() == 0 else 1
        target_day = (ref - dt.timedelta(days=days_back)).date()
        since_dt = dt.datetime.combine(target_day, dt.time.min, tzinfo=ref.tzinfo)
        label = f"Friday {target_day.isoformat()}" if days_back == 3 else f"yesterday ({target_day.isoformat()})"
        return since_dt, label

    if lower == "today":
        target_day = ref.date()
        since_dt = dt.datetime.combine(target_day, dt.time.min, tzinfo=ref.tzinfo)
        return since_dt, f"today ({target_day.isoformat()})"

    m = DURATION_RE.match(lower)
    if m:
        num = int(m.group("num"))
        if num < 1:
            raise RecapError(f"invalid --since duration: {raw}")
        unit = m.group("unit")
        if unit == "h":
            since_dt = ref - dt.timedelta(hours=num)
        elif unit == "d":
            since_dt = ref - dt.timedelta(days=num)
        else:
            since_dt = ref - dt.timedelta(weeks=num)
        return since_dt, f"last {num}{unit} (since {since_dt.strftime('%Y-%m-%d')})"

    if re.match(r"^\d{4}-\d{2}-\d{2}$", raw):
        try:
            d = dt.date.fromisoformat(raw)
        except ValueError as exc:
            raise RecapError(f"invalid --since date: {raw}") from exc
        since_dt = dt.datetime.combine(d, dt.time.min, tzinfo=ref.tzinfo)
        return since_dt, d.isoformat()

    try:
        parsed = parse_iso(raw)
    except ValueError as exc:
        raise RecapError(
            f"invalid --since value '{raw}' (use e.g. yesterday, today, 24h, 7d, 2w, or YYYY-MM-DD)"
        ) from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=ref.tzinfo)
    return parsed, parsed.strftime("%Y-%m-%d %H:%M")


def extract_github_org_repo(remote_url):
    m = GITHUB_REMOTE_RE.match((remote_url or "").strip())
    if not m:
        return None
    return m.group("org"), m.group("repo")


def is_allowed_org(org, allowed_orgs):
    if not org:
        return False
    allowed = {o.lower() for o in allowed_orgs if o}
    return org.lower() in allowed


def clean_excerpt(text, limit=400):
    if not text:
        return ""
    lines = []
    for raw in str(text).splitlines():
        line = raw.strip()
        if not line or line.startswith("<!--"):
            continue
        lines.append(line)
    joined = " ".join(lines)
    joined = re.sub(r"\s+", " ", joined).strip()
    if len(joined) > limit:
        return joined[: limit - 1].rstrip() + "…"
    return joined


def extract_tickets(texts, jira_projects=None):
    if jira_projects:
        prefixes = "|".join(re.escape(p) for p in jira_projects if p)
        pattern = re.compile(rf"\b(?:{prefixes})-\d+\b")
    else:
        pattern = re.compile(r"\b[A-Z][A-Z0-9]{1,9}-\d+\b")
    seen = []
    for text in texts:
        if not text:
            continue
        for match in pattern.findall(str(text)):
            if match not in seen:
                seen.append(match)
    return seen


def summarize_ci(rollup):
    if not rollup:
        return "none"
    failing = []
    pending = []
    passing = 0
    for item in rollup:
        if not isinstance(item, dict):
            continue
        name = item.get("name") or item.get("context") or "check"
        conclusion = (item.get("conclusion") or "").upper()
        status = (item.get("status") or "").upper()
        state = (item.get("state") or "").upper()
        if conclusion in ("FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR") or state in ("FAILURE", "ERROR"):
            failing.append(name)
        elif (status and status != "COMPLETED") or state in ("PENDING", "EXPECTED"):
            pending.append(name)
        elif conclusion in ("SUCCESS", "NEUTRAL", "SKIPPED") or state == "SUCCESS":
            passing += 1
    if failing:
        shown = ", ".join(failing[:3])
        extra = f" +{len(failing) - 3}" if len(failing) > 3 else ""
        return f"failing ({shown}{extra})"
    if pending:
        return f"pending ({len(pending)})"
    if passing:
        return "passing"
    return "none"


def summarize_reviews(review_decision, reviews, comments):
    decision = (review_decision or "").upper()
    reviewers = []
    notes = []
    latest_state_by_author = {}

    for rev in reviews or []:
        if not isinstance(rev, dict):
            continue
        author = (rev.get("author") or {}).get("login") or ""
        state = (rev.get("state") or "").upper()
        body = clean_excerpt(rev.get("body"), limit=200)
        if author and state in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            latest_state_by_author[author] = state
        if author and author not in reviewers:
            reviewers.append(author)
        if body:
            notes.append(f"{author or 'reviewer'}: {body}")

    for cmt in (comments or [])[-5:]:
        if not isinstance(cmt, dict):
            continue
        author = (cmt.get("author") or {}).get("login") or ""
        body = clean_excerpt(cmt.get("body"), limit=200)
        if body:
            notes.append(f"{author or 'comment'}: {body}")

    if not decision:
        states = set(latest_state_by_author.values())
        if "CHANGES_REQUESTED" in states:
            decision = "CHANGES_REQUESTED"
        elif "APPROVED" in states:
            decision = "APPROVED"
        else:
            decision = "REVIEW_REQUIRED"

    label_map = {
        "APPROVED": "approved",
        "CHANGES_REQUESTED": "changes requested",
        "REVIEW_REQUIRED": "review needed",
    }
    return {
        "state": label_map.get(decision, decision.lower()),
        "reviewers": reviewers[:6],
        "notes": notes[-4:],
    }


def run_cmd(args, cwd=None, timeout=30):
    try:
        proc = subprocess.run(
            args,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except FileNotFoundError:
        return 127, "", f"command not found: {args[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out: {' '.join(args[:4])}"


def fetch_pr_detail(repo_slug, number, jira_projects):
    fields = (
        "number,title,url,body,isDraft,mergedAt,updatedAt,headRefName,"
        "additions,deletions,changedFiles,files,reviewDecision,statusCheckRollup,reviews,comments"
    )
    code, out, _ = run_cmd(
        ["gh", "pr", "view", str(number), "--repo", repo_slug, "--json", fields],
        timeout=30,
    )
    if code != 0 or not out.strip():
        return None
    try:
        pr = json.loads(out)
    except json.JSONDecodeError:
        return None

    files = [f.get("path") for f in (pr.get("files") or []) if isinstance(f, dict) and f.get("path")]
    review_info = summarize_reviews(pr.get("reviewDecision"), pr.get("reviews"), pr.get("comments"))
    tickets = extract_tickets(
        [pr.get("title"), pr.get("headRefName"), pr.get("body")],
        jira_projects=jira_projects,
    )
    return {
        "repo": repo_slug,
        "number": pr.get("number", number),
        "title": pr.get("title", ""),
        "url": pr.get("url", ""),
        "branch": pr.get("headRefName", ""),
        "draft": bool(pr.get("isDraft")),
        "merged_at": pr.get("mergedAt") or "",
        "updated_at": pr.get("updatedAt") or "",
        "body": clean_excerpt(pr.get("body"), limit=900),
        "additions": int(pr.get("additions") or 0),
        "deletions": int(pr.get("deletions") or 0),
        "changed_files": int(pr.get("changedFiles") or len(files)),
        "files": files[:15],
        "ci": summarize_ci(pr.get("statusCheckRollup")),
        "review": review_info["state"],
        "reviewers": review_info["reviewers"],
        "review_notes": review_info["notes"],
        "tickets": tickets,
    }


def collect_github(orgs, since_dt, jira_projects, warnings):
    if not shutil.which("gh"):
        warnings.append("gh CLI not found; skipped GitHub PRs")
        return [], []

    since_utc = since_dt.astimezone(dt.timezone.utc)
    since_date = since_dt.strftime("%Y-%m-%d")
    merged_candidates = []
    open_candidates = []
    seen_merged = set()
    seen_open = set()

    for org in orgs:
        # Merged PRs authored by @me in this org
        code, out, err = run_cmd(
            [
                "gh", "search", "prs",
                "--author", "@me",
                "--owner", org,
                "--merged",
                "--merged-at", f">={since_date}",
                "--limit", "50",
                "--json", "number,title,url,repository,closedAt,updatedAt",
            ],
            timeout=30,
        )
        if code != 0:
            msg = clean_excerpt(err, 160) or f"exit {code}"
            warnings.append(f"gh merged PR search for {org} failed: {msg}")
        else:
            try:
                rows = json.loads(out) if out.strip() else []
            except json.JSONDecodeError:
                rows = []
            for row in rows:
                slug = (row.get("repository") or {}).get("nameWithOwner") or ""
                if "/" not in slug:
                    continue
                row_org = slug.split("/", 1)[0]
                if not is_allowed_org(row_org, orgs):
                    continue
                key = (slug.lower(), int(row.get("number") or 0))
                if key[1] and key not in seen_merged:
                    seen_merged.add(key)
                    merged_candidates.append((slug, key[1]))

        # Open PRs authored by @me in this org
        code, out, err = run_cmd(
            [
                "gh", "search", "prs",
                "--author", "@me",
                "--owner", org,
                "--state", "open",
                "--limit", "50",
                "--json", "number,title,url,repository,updatedAt,isDraft",
            ],
            timeout=30,
        )
        if code != 0:
            msg = clean_excerpt(err, 160) or f"exit {code}"
            warnings.append(f"gh open PR search for {org} failed: {msg}")
        else:
            try:
                rows = json.loads(out) if out.strip() else []
            except json.JSONDecodeError:
                rows = []
            for row in rows:
                slug = (row.get("repository") or {}).get("nameWithOwner") or ""
                if "/" not in slug:
                    continue
                row_org = slug.split("/", 1)[0]
                if not is_allowed_org(row_org, orgs):
                    continue
                key = (slug.lower(), int(row.get("number") or 0))
                if key[1] and key not in seen_open:
                    seen_open.add(key)
                    open_candidates.append((slug, key[1]))

    all_targets = [("merged", s, n) for s, n in merged_candidates] + [("open", s, n) for s, n in open_candidates]
    merged_prs = []
    open_prs = []

    if all_targets:
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(6, len(all_targets))) as pool:
            future_map = {
                pool.submit(fetch_pr_detail, slug, num, jira_projects): (kind, slug, num)
                for kind, slug, num in all_targets
            }
            for fut in concurrent.futures.as_completed(future_map):
                kind, _, _ = future_map[fut]
                detail = fut.result()
                if not detail:
                    continue
                if kind == "merged":
                    if detail["merged_at"]:
                        try:
                            merged_dt = parse_iso(detail["merged_at"]).astimezone(dt.timezone.utc)
                            if merged_dt < since_utc:
                                continue
                        except ValueError:
                            pass
                    merged_prs.append(detail)
                else:
                    open_prs.append(detail)

    merged_prs.sort(key=lambda p: p.get("merged_at") or p.get("updated_at") or "", reverse=True)
    open_prs.sort(key=lambda p: p.get("updated_at") or "", reverse=True)
    return merged_prs, open_prs


def discover_local_repos(config_repos, repo_roots):
    candidates = []
    seen = set()

    def add_if_git(path):
        expanded = os.path.expanduser(path)
        if not os.path.isdir(expanded):
            return
        if not os.path.exists(os.path.join(expanded, ".git")):
            return
        real = os.path.realpath(expanded)
        if real not in seen:
            seen.add(real)
            candidates.append(real)

    for path in (config_repos or {}).values():
        if isinstance(path, str) and path.strip():
            add_if_git(path)

    for root in repo_roots or []:
        if not isinstance(root, str) or not root.strip():
            continue
        expanded = os.path.expanduser(root)
        if not os.path.isdir(expanded):
            continue
        if os.path.exists(os.path.join(expanded, ".git")):
            add_if_git(expanded)
            continue
        try:
            with os.scandir(expanded) as entries:
                for entry in entries:
                    if entry.is_dir(follow_symlinks=True) and not entry.name.startswith("."):
                        add_if_git(entry.path)
        except OSError:
            continue

    return candidates


def repo_github_slug(repo_path, orgs):
    code, out, _ = run_cmd(["git", "-C", repo_path, "remote", "-v"], timeout=10)
    if code != 0:
        return None
    # Prefer origin, then any other remote matching orgs
    origin_slug = None
    fallback_slug = None
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        remote_name, url = parts[0], parts[1]
        parsed = extract_github_org_repo(url)
        if not parsed:
            continue
        org, repo = parsed
        if not is_allowed_org(org, orgs):
            continue
        slug = f"{org}/{repo}"
        if remote_name == "origin":
            origin_slug = slug
            break
        if fallback_slug is None:
            fallback_slug = slug
    return origin_slug or fallback_slug


def collect_local_git(repo_paths, orgs, since_dt, jira_projects, warnings):
    if not shutil.which("git"):
        warnings.append("git not found; skipped local git repos")
        return [], {}

    since_utc = since_dt.astimezone(dt.timezone.utc)
    since_iso = since_utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    items = []
    # Map lowercase identifiers (realpath, basename, org/repo) -> canonical org/repo
    allowed_repo_index = {}

    for path in repo_paths:
        slug = repo_github_slug(path, orgs)
        if not slug:
            continue
        allowed_repo_index[path.lower()] = slug
        allowed_repo_index[os.path.basename(path).lower()] = slug
        allowed_repo_index[slug.lower()] = slug
        allowed_repo_index[slug.split("/", 1)[1].lower()] = slug

        _, branch_out, _ = run_cmd(["git", "-C", path, "symbolic-ref", "--short", "HEAD"], timeout=10)
        current_branch = branch_out.strip()
        if not current_branch:
            _, sha_out, _ = run_cmd(["git", "-C", path, "rev-parse", "--short", "HEAD"], timeout=10)
            current_branch = f"detached@{sha_out.strip()}" if sha_out.strip() else "HEAD"

        _, status_out, _ = run_cmd(["git", "-C", path, "status", "--porcelain"], timeout=10)
        dirty_files = []
        staged = modified = untracked = 0
        for line in status_out.splitlines():
            if len(line) < 4:
                continue
            xy = line[:2]
            fname = line[3:].strip()
            dirty_files.append(fname)
            if xy == "??":
                untracked += 1
            else:
                if xy[0] not in (" ", "?"):
                    staged += 1
                if xy[1] not in (" ", "?"):
                    modified += 1

        ahead = behind = 0
        code, ab_out, _ = run_cmd(
            ["git", "-C", path, "rev-list", "--left-right", "--count", "@{u}...HEAD"],
            timeout=10,
        )
        if code == 0 and len(ab_out.split()) == 2:
            behind, ahead = (int(x) for x in ab_out.split())

        _, refs_out, _ = run_cmd(
            [
                "git", "-C", path, "for-each-ref",
                "--sort=-committerdate",
                "--format=%(refname:short)\t%(committerdate:iso-strict)\t%(subject)",
                "refs/heads",
            ],
            timeout=10,
        )
        active_branches = []
        for line in refs_out.splitlines():
            parts = line.split("\t", 2)
            if len(parts) < 3:
                continue
            bname, bdate, bsubj = parts
            try:
                bdt = parse_iso(bdate).astimezone(dt.timezone.utc)
            except ValueError:
                continue
            if bdt >= since_utc:
                active_branches.append(
                    {
                        "name": bname,
                        "updated_at": bdate,
                        "subject": clean_excerpt(bsubj, 120),
                    }
                )

        _, email_out, _ = run_cmd(["git", "-C", path, "config", "user.email"], timeout=10)
        user_email = email_out.strip()
        log_cmd = [
            "git", "-C", path, "log",
            "--all",
            f"--since={since_iso}",
            "--no-merges",
            "--max-count=10",
            "--format=%h\t%D\t%s",
        ]
        if user_email:
            log_cmd.append(f"--author={user_email}")
        _, log_out, _ = run_cmd(log_cmd, timeout=10)
        recent_commits = []
        for line in log_out.splitlines():
            parts = line.split("\t", 2)
            if len(parts) == 3:
                recent_commits.append({"sha": parts[0], "refs": parts[1], "subject": clean_excerpt(parts[2], 120)})

        if not dirty_files and ahead == 0 and not active_branches and not recent_commits:
            continue

        tickets = extract_tickets(
            [current_branch]
            + [b["name"] for b in active_branches]
            + [c["subject"] for c in recent_commits],
            jira_projects=jira_projects,
        )
        items.append(
            {
                "repo": slug,
                "path": path,
                "branch": current_branch,
                "dirty": {
                    "total": len(dirty_files),
                    "staged": staged,
                    "modified": modified,
                    "untracked": untracked,
                    "files": dirty_files[:10],
                },
                "ahead": ahead,
                "behind": behind,
                "active_branches": active_branches[:8],
                "recent_commits": recent_commits[:8],
                "tickets": tickets,
            }
        )

    items.sort(key=lambda x: x["repo"].lower())
    return items, allowed_repo_index


def read_keychain(service):
    code, out, _ = run_cmd(["security", "find-generic-password", "-s", service, "-w"], timeout=5)
    return out.strip() if code == 0 and out.strip() else None


def langfuse_keys():
    pk = os.environ.get("LANGFUSE_PUBLIC_KEY")
    sk = os.environ.get("LANGFUSE_SECRET_KEY")
    if pk and sk:
        return pk, sk
    key_dir = os.environ.get("LANGFUSE_KEY_DIR")
    if key_dir:
        try:
            with open(os.path.join(key_dir, "lf_pk"), encoding="utf-8") as f:
                pk = f.read().strip()
            with open(os.path.join(key_dir, "lf_sk"), encoding="utf-8") as f:
                sk = f.read().strip()
            if pk and sk:
                return pk, sk
        except OSError:
            pass
    if sys.platform == "darwin":
        pk = read_keychain("langfuse-local-public-key")
        sk = read_keychain("langfuse-local-secret-key")
        if pk and sk:
            return pk, sk
    return None, None


def match_langfuse_repo(record, orgs, allowed_repo_index):
    """Return canonical 'org/repo' if a Langfuse observation/trace belongs to an allowed org, else None."""
    meta = record.get("metadata") if isinstance(record.get("metadata"), dict) else {}
    tags = record.get("tags") if isinstance(record.get("tags"), list) else []
    candidates = []

    for key in ("repo", "repository", "git_remote", "gitRemote", "remote", "cwd", "workdir", "project", "workspace"):
        val = meta.get(key)
        if isinstance(val, str) and val.strip():
            candidates.append(val.strip())
    for tag in tags:
        if isinstance(tag, str) and tag.strip():
            candidates.append(tag.strip())
    name = record.get("name")
    if isinstance(name, str) and name.strip():
        candidates.append(name.strip())

    for val in candidates:
        # 1. Exact git remote URL
        parsed = extract_github_org_repo(val)
        if parsed and is_allowed_org(parsed[0], orgs):
            return f"{parsed[0]}/{parsed[1]}"

        # 2. Explicit org/repo slug
        for m in GITHUB_SLUG_RE.finditer(val):
            org, repo = m.group("org"), m.group("repo").removesuffix(".git")
            if is_allowed_org(org, orgs):
                return f"{org}/{repo}"

        # 3. Verified local repo path or basename
        low = val.lower().rstrip("/")
        if low in allowed_repo_index:
            return allowed_repo_index[low]
        expanded = os.path.expanduser(val).lower().rstrip("/")
        if expanded in allowed_repo_index:
            return allowed_repo_index[expanded]
        for repo_path, slug in allowed_repo_index.items():
            if "/" in repo_path and (expanded == repo_path or expanded.startswith(repo_path + "/")):
                return slug

    return None


def extract_langfuse_snippet(record):
    raw_in = record.get("input")
    if isinstance(raw_in, str):
        return clean_excerpt(raw_in, 240)
    if isinstance(raw_in, dict):
        for key in ("prompt", "task", "message", "text", "query", "content"):
            if isinstance(raw_in.get(key), str) and raw_in[key].strip():
                return clean_excerpt(raw_in[key], 240)
        msgs = raw_in.get("messages")
        if isinstance(msgs, list):
            for msg in msgs:
                if isinstance(msg, dict) and msg.get("role") == "user":
                    content = msg.get("content")
                    if isinstance(content, str) and content.strip():
                        return clean_excerpt(content, 240)
    if isinstance(raw_in, list):
        for msg in raw_in:
            if isinstance(msg, dict) and msg.get("role") == "user":
                content = msg.get("content")
                if isinstance(content, str) and content.strip():
                    return clean_excerpt(content, 240)
    name = record.get("name")
    return clean_excerpt(name, 160) if isinstance(name, str) else ""


def collect_langfuse(url, orgs, since_dt, allowed_repo_index, jira_projects, warnings):
    base_url = (url or "").strip().rstrip("/")
    if not base_url:
        return []

    pk, sk = langfuse_keys()
    if not (pk and sk):
        warnings.append("Langfuse keys not found; skipped Langfuse sessions")
        return []

    headers = {
        "Authorization": "Basic " + base64.b64encode(f"{pk}:{sk}".encode()).decode(),
        "Accept": "application/json",
    }
    since_utc = since_dt.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    records = []
    # Try v2 observations first (Langfuse v4 events_only), fall back to /api/public/traces on 404
    cursor = None
    use_traces_fallback = False
    for _ in range(5):
        params = {"limit": "200", "fromStartTime": since_utc, "fields": "core,basic,metadata,io"}
        if cursor:
            params["cursor"] = cursor
        req_url = f"{base_url}/api/public/v2/observations?" + urllib.parse.urlencode(params)
        try:
            with urllib.request.urlopen(urllib.request.Request(req_url, headers=headers), timeout=15) as resp:
                payload = json.load(resp)
        except urllib.error.HTTPError as exc:
            if exc.code == 404 and not records:
                use_traces_fallback = True
                break
            warnings.append(f"Langfuse HTTP {exc.code}; skipped Langfuse sessions")
            return []
        except Exception as exc:
            warnings.append(f"Langfuse unreachable ({type(exc).__name__}); skipped Langfuse sessions")
            return []
        batch = payload.get("data") or []
        records.extend(batch)
        cursor = (payload.get("meta") or {}).get("cursor")
        if not cursor or not batch:
            break

    if use_traces_fallback:
        params = {"limit": "100", "fromTimestamp": since_utc}
        req_url = f"{base_url}/api/public/traces?" + urllib.parse.urlencode(params)
        try:
            with urllib.request.urlopen(urllib.request.Request(req_url, headers=headers), timeout=15) as resp:
                payload = json.load(resp)
            records = payload.get("data") or []
        except Exception as exc:
            warnings.append(f"Langfuse traces fetch failed ({type(exc).__name__}); skipped Langfuse sessions")
            return []

    sessions = {}
    for rec in records:
        if not isinstance(rec, dict):
            continue
        sid = rec.get("sessionId") or rec.get("traceId") or rec.get("id")
        if not sid:
            continue
        entry = sessions.setdefault(
            sid,
            {
                "session_id": sid,
                "repo": None,
                "environment": rec.get("environment") or "",
                "started_at": rec.get("startTime") or rec.get("timestamp") or "",
                "ended_at": rec.get("endTime") or rec.get("startTime") or rec.get("timestamp") or "",
                "calls": 0,
                "snippet": "",
            },
        )
        entry["calls"] += 1
        if not entry["repo"]:
            entry["repo"] = match_langfuse_repo(rec, orgs, allowed_repo_index)
        if not entry["environment"] and rec.get("environment"):
            entry["environment"] = rec["environment"]
        ts = rec.get("startTime") or rec.get("timestamp") or ""
        if ts and (not entry["started_at"] or ts < entry["started_at"]):
            entry["started_at"] = ts
        if ts and ts > entry["ended_at"]:
            entry["ended_at"] = ts
        if not entry["snippet"]:
            entry["snippet"] = extract_langfuse_snippet(rec)

    matched = []
    for entry in sessions.values():
        if not entry["repo"]:
            continue
        entry["tickets"] = extract_tickets([entry["snippet"]], jira_projects=jira_projects)
        matched.append(entry)

    matched.sort(key=lambda s: s.get("ended_at") or s.get("started_at") or "", reverse=True)
    return matched[:15]


def format_raw(data):
    win = data["window"]
    orgs = ", ".join(data["orgs"])
    lines = [f"Work recap ({win['label']} → {win['until'][:10]}, orgs: {orgs})"]

    merged = data["merged_prs"]
    open_prs = data["open_prs"]
    local = data["local_git"]
    lf = data["langfuse_sessions"]
    warnings = data["warnings"]

    if not merged and not open_prs and not local and not lf:
        lines.append("")
        lines.append(f"No activity found in {orgs} since {win['label']}.")
        if warnings:
            lines.append("")
            lines.append("Notes:")
            for w in warnings:
                lines.append(f"- {w}")
        return "\n".join(lines)

    if merged:
        lines.append("")
        lines.append(f"Merged PRs ({len(merged)}):")
        for pr in merged:
            tickets = f" [{', '.join(pr['tickets'])}]" if pr.get("tickets") else ""
            lines.append(
                f"- {pr['repo']} #{pr['number']}{tickets}: {pr['title']} "
                f"(+{pr['additions']}/-{pr['deletions']}, {pr['changed_files']} files) {pr['url']}"
            )
            if pr.get("body"):
                lines.append(f"  {clean_excerpt(pr['body'], 200)}")

    if open_prs:
        lines.append("")
        lines.append(f"Open PRs ({len(open_prs)}):")
        for pr in open_prs:
            draft = " [draft]" if pr.get("draft") else ""
            tickets = f" [{', '.join(pr['tickets'])}]" if pr.get("tickets") else ""
            lines.append(
                f"- {pr['repo']} #{pr['number']}{draft}{tickets}: {pr['title']} "
                f"— CI: {pr['ci']}, review: {pr['review']} "
                f"(+{pr['additions']}/-{pr['deletions']}) {pr['url']}"
            )

    if local:
        lines.append("")
        lines.append(f"Local Git ({len(local)}):")
        for repo in local:
            bits = [f"branch `{repo['branch']}`"]
            dirty = repo["dirty"]
            if dirty["total"]:
                bits.append(f"{dirty['total']} dirty ({dirty['staged']} staged, {dirty['modified']} mod, {dirty['untracked']} untracked)")
            if repo["ahead"]:
                bits.append(f"{repo['ahead']} ahead")
            if repo["behind"]:
                bits.append(f"{repo['behind']} behind")
            lines.append(f"- {repo['repo']}: {', '.join(bits)}")
            if dirty["files"]:
                sample = ", ".join(dirty["files"][:5])
                extra = f" +{dirty['total'] - 5}" if dirty["total"] > 5 else ""
                lines.append(f"  dirty: {sample}{extra}")
            if repo["recent_commits"]:
                for c in repo["recent_commits"][:3]:
                    lines.append(f"  commit {c['sha']}: {c['subject']}")

    if lf:
        lines.append("")
        lines.append(f"Langfuse Sessions ({len(lf)}):")
        for s in lf:
            env = f" ({s['environment']})" if s.get("environment") else ""
            snippet = f" — {s['snippet']}" if s.get("snippet") else ""
            lines.append(f"- {s['repo']}{env}, {s['calls']} calls{snippet}")

    if warnings:
        lines.append("")
        lines.append("Notes:")
        for w in warnings:
            lines.append(f"- {w}")

    return "\n".join(lines)


def build_recap(config, since_spec=None, now=None):
    recap_cfg = config.get("recap") if isinstance(config.get("recap"), dict) else {}
    orgs = [o.strip() for o in (recap_cfg.get("github_orgs") or []) if isinstance(o, str) and o.strip()]
    if not orgs:
        raise RecapError(
            "recap.github_orgs is empty; configure at least one GitHub org "
            "(e.g. agent-relay config set recap.github_orgs '[\"my-org\"]')"
        )

    ref_now = now if now is not None else local_now()
    since_dt, since_label = resolve_since(since_spec, now=ref_now)
    jira_projects = config.get("jira_projects") or []
    warnings = []

    merged_prs, open_prs = collect_github(orgs, since_dt, jira_projects, warnings)

    repo_paths = discover_local_repos(config.get("repos") or {}, recap_cfg.get("repo_roots") or [])
    local_git, allowed_repo_index = collect_local_git(repo_paths, orgs, since_dt, jira_projects, warnings)

    # Also register repos seen on GitHub in allowed_repo_index for Langfuse matching
    for pr in merged_prs + open_prs:
        slug = pr.get("repo") or ""
        if "/" in slug:
            allowed_repo_index.setdefault(slug.lower(), slug)
            allowed_repo_index.setdefault(slug.split("/", 1)[1].lower(), slug)

    langfuse_url = os.environ.get("AGENT_RELAY_LANGFUSE_URL") or recap_cfg.get("langfuse_url") or ""
    langfuse_sessions = collect_langfuse(
        langfuse_url, orgs, since_dt, allowed_repo_index, jira_projects, warnings
    )

    return {
        "window": {
            "since": since_dt.isoformat(),
            "until": ref_now.isoformat(),
            "label": since_label,
        },
        "orgs": orgs,
        "merged_prs": merged_prs,
        "open_prs": open_prs,
        "local_git": local_git,
        "langfuse_sessions": langfuse_sessions,
        "warnings": warnings,
    }


def main():
    parser = argparse.ArgumentParser(description="Collect scoped work recap data")
    parser.add_argument("--config-json", required=True, help="Effective agent-relay config as JSON string")
    parser.add_argument("--since", default="", help="Lookback window (e.g. yesterday, today, 24h, 7d, 2w, YYYY-MM-DD)")
    parser.add_argument("--format", choices=("raw", "json"), default="json")
    parser.add_argument("--now", default="", help="Override current time (ISO-8601, for tests)")
    args = parser.parse_args()

    try:
        config = json.loads(args.config_json)
    except json.JSONDecodeError as exc:
        print(f"agent-relay recap: invalid config JSON: {exc}", file=sys.stderr)
        return 1

    try:
        data = build_recap(config, since_spec=args.since, now=local_now(args.now) if args.now else None)
    except RecapError as exc:
        print(f"agent-relay recap: {exc}", file=sys.stderr)
        return 2

    if args.format == "raw":
        print(format_raw(data))
    else:
        print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
