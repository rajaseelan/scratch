```markdown
# GCP Folder → GKE Clusters Scan

Session notes and working code: recursively walk a GCP folder hierarchy, list/describe GKE clusters in descendant projects, store results in SQLite (keep last 20 queries), with notes on multithreading and evolving schema.

---

## 1. Goal

Given a **folder ID**:

1. Recursively traverse folders and collect projects.
2. List (and optionally describe) GKE clusters in those projects.
3. Store each run in SQLite.
4. Retain only the **last 20 queries**, dropping the oldest automatically.
5. Prefer concurrency at the **project** level (not deep folder recursion).
6. Allow cluster fields to grow over time without painful migrations.

---

## 2. Architecture summary

| Concern | Approach |
|--------|----------|
| Hierarchy | Resource Manager: folders → child folders + direct projects |
| Clusters | Container API / `gcloud container clusters list` (all locations) |
| Concurrency | Sequential folder walk; parallel **per-project** cluster listing |
| Storage | SQLite: `queries` + `gke_clusters` |
| Retention | `AFTER INSERT` trigger keeps newest 20 query rows |
| Schema growth | Core columns + full `config_json` |
| Auth | `gcloud` user auth or Application Default Credentials (ADC) |

**Permissions (typical):**

- `resourcemanager.folders.list` / folder viewer on the tree  
- `resourcemanager.projects.list`  
- `container.clusters.list` (and `get` if you fully describe)

---

## 3. SQLite design

### Schema

```sql
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS queries (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    folder_id   TEXT,
    notes       TEXT
);

CREATE TABLE IF NOT EXISTS gke_clusters (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    query_id        INTEGER NOT NULL REFERENCES queries(id) ON DELETE CASCADE,
    project_id      TEXT,
    cluster_name    TEXT,
    location        TEXT,
    status          TEXT,
    master_version  TEXT,
    node_count      INTEGER,
    endpoint        TEXT,
    config_json     TEXT NOT NULL,
    collected_at    TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_gke_clusters_query_id ON gke_clusters(query_id);
```

### Native retention (last 20 queries)

SQLite has no built-in “keep last N” policy, but a **trigger** enforces it in the database:

```sql
CREATE TRIGGER IF NOT EXISTS keep_last_20_queries
AFTER INSERT ON queries
BEGIN
    DELETE FROM queries
    WHERE id NOT IN (
        SELECT id FROM queries ORDER BY id DESC LIMIT 20
    );
END;
```

Deleting a `queries` row cascades to its `gke_clusters` rows when foreign keys are on.

### Evolving fields over time

- Always store the **full cluster resource** in `config_json`.
- Promote fields to real columns only when you filter/sort/report on them often.

Example later migration:

```sql
ALTER TABLE gke_clusters ADD COLUMN release_channel TEXT;

UPDATE gke_clusters
SET release_channel = json_extract(config_json, '$.releaseChannel.channel')
WHERE release_channel IS NULL;
```

---

## 4. Multithreading

### SQLite

- Fine under moderate concurrency with **WAL** and short write transactions.
- Prefer **one connection per thread**, or a shared connection protected by a lock for writes.
- For this workload (infrequent scans, small row counts), DB cost is **negligible** vs GCP API latency.

### GCP traversal

| Layer | Multithread? | Notes |
|--------|--------------|--------|
| Folder recursion | Usually no | Hierarchical; little gain |
| Project listing under a folder | Optional | Often fine sequential |
| **Clusters per project** | **Yes** | Main win; I/O bound |

Recommended pattern:

1. Collect all project IDs (mostly sequential).
2. Fan out cluster listing with a small pool (e.g. 4–8 workers).
3. Write SQLite from one place (or locked), one transaction per run.

Watch **Container API / Resource Manager quotas**; handle `429` with backoff if needed.

---

## 5. Code set A — gcloud CLI (Bash)

**Dependencies:** `gcloud`, `sqlite3`, `jq`  
**Usage:**

```bash
chmod +x gke-folder-scan.sh
./gke-folder-scan.sh <FOLDER_ID> [DB_PATH]
PARALLEL_JOBS=8 ./gke-folder-scan.sh 123456789012 ./gke_history.db
```

```bash
#!/usr/bin/env bash
# gke-folder-scan.sh
# Usage: ./gke-folder-scan.sh <FOLDER_ID> [DB_PATH]
set -euo pipefail

FOLDER_ID="${1:?Usage: $0 <FOLDER_ID> [DB_PATH]}"
DB_PATH="${2:-gke_history.db}"
PARALLEL_JOBS="${PARALLEL_JOBS:-6}"

need() { command -v "$1" >/dev/null || { echo "Missing: $1" >&2; exit 1; }; }
need gcloud
need sqlite3
need jq

init_db() {
  sqlite3 "$DB_PATH" <<'SQL'
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS queries (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    folder_id   TEXT,
    notes       TEXT
);

CREATE TABLE IF NOT EXISTS gke_clusters (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    query_id        INTEGER NOT NULL REFERENCES queries(id) ON DELETE CASCADE,
    project_id      TEXT,
    cluster_name    TEXT,
    location        TEXT,
    status          TEXT,
    master_version  TEXT,
    node_count      INTEGER,
    endpoint        TEXT,
    config_json     TEXT NOT NULL,
    collected_at    TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_gke_clusters_query_id ON gke_clusters(query_id);

CREATE TRIGGER IF NOT EXISTS keep_last_20_queries
AFTER INSERT ON queries
BEGIN
    DELETE FROM queries
    WHERE id NOT IN (
        SELECT id FROM queries ORDER BY id DESC LIMIT 20
    );
END;
SQL
}

collect_projects() {
  local parent="$1"
  gcloud projects list \
    --filter="parent.id=${parent} AND parent.type=folder" \
    --format="value(projectId)" 2>/dev/null || true

  local child
  while IFS= read -r child; do
    [[ -z "$child" ]] && continue
    local child_id="${child##*/}"
    collect_projects "$child_id"
  done < <(gcloud resource-manager folders list \
              --folder="${parent}" \
              --format="value(name)" 2>/dev/null || true)
}

fetch_project_clusters() {
  local project="$1"
  local tmp
  tmp="$(mktemp)"

  if ! gcloud container clusters list \
        --project="$project" \
        --format=json >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi

  jq -c --arg p "$project" '.[]? // empty | {
      project_id: $p,
      name: .name,
      location: .location,
      status: (.status // ""),
      master_version: (.currentMasterVersion // ""),
      node_count: (.currentNodeCount // 0),
      endpoint: (.endpoint // ""),
      raw: .
    }' "$tmp" 2>/dev/null \
  | while IFS= read -r row; do
      echo "$row"
    done

  rm -f "$tmp"
}

export -f fetch_project_clusters

main() {
  init_db

  echo "Discovering projects under folder ${FOLDER_ID}..."
  mapfile -t PROJECTS < <(collect_projects "$FOLDER_ID" | sort -u)

  if [[ ${#PROJECTS[@]} -eq 0 ]]; then
    echo "No projects found."
    exit 0
  fi
  echo "Found ${#PROJECTS[@]} project(s)."

  local query_id
  query_id="$(sqlite3 "$DB_PATH" "INSERT INTO queries (folder_id, notes) VALUES ('${FOLDER_ID//\'/\'\'}', 'gcloud scan'); SELECT last_insert_rowid();")"

  local results_file
  results_file="$(mktemp)"

  printf '%s\n' "${PROJECTS[@]}" \
    | xargs -P "$PARALLEL_JOBS" -I{} bash -c 'fetch_project_clusters "$@"' _ {} \
    >"$results_file" || true

  local count=0
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    local project name location status version nodes endpoint json_sql
    project=$(jq -r '.project_id' <<<"$row")
    name=$(jq -r '.name' <<<"$row")
    location=$(jq -r '.location' <<<"$row")
    status=$(jq -r '.status' <<<"$row")
    version=$(jq -r '.master_version' <<<"$row")
    nodes=$(jq -r '.node_count' <<<"$row")
    endpoint=$(jq -r '.endpoint' <<<"$row")
    json_sql=$(jq -c '.raw' <<<"$row" | sed "s/'/''/g")

    sqlite3 "$DB_PATH" <<SQL
PRAGMA foreign_keys = ON;
INSERT INTO gke_clusters
  (query_id, project_id, cluster_name, location, status,
   master_version, node_count, endpoint, config_json)
VALUES
  ($query_id,
   '${project//\'/\'\'}',
   '${name//\'/\'\'}',
   '${location//\'/\'\'}',
   '${status//\'/\'\'}',
   '${version//\'/\'\'}',
   $nodes,
   '${endpoint//\'/\'\'}',
   '$json_sql');
SQL
    count=$((count + 1))
  done <"$results_file"

  rm -f "$results_file"
  echo "Saved query_id=$query_id with $count cluster row(s) → $DB_PATH"
  echo "Retention: last 20 queries (trigger)."
}

main
```

---

## 6. Code set B — GCP Python API

**Install:**

```bash
pip install google-cloud-resource-manager google-cloud-container
```

**Usage:**

```bash
python gke_folder_scan.py --folder-id 123456789012 --db gke_history.db --workers 8
```

```python
#!/usr/bin/env python3
"""
gke_folder_scan.py

Recursively walk a GCP folder, list GKE clusters in descendant projects,
store results in SQLite (keep last 20 queries). Hybrid schema: core columns + config_json.

Usage:
  python gke_folder_scan.py --folder-id 123456789012 --db gke_history.db --workers 8
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import concurrent.futures
from typing import Any

from google.cloud import resourcemanager_v3
from google.cloud import container_v1


SCHEMA = """
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS queries (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    folder_id   TEXT,
    notes       TEXT
);

CREATE TABLE IF NOT EXISTS gke_clusters (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    query_id        INTEGER NOT NULL REFERENCES queries(id) ON DELETE CASCADE,
    project_id      TEXT,
    cluster_name    TEXT,
    location        TEXT,
    status          TEXT,
    master_version  TEXT,
    node_count      INTEGER,
    endpoint        TEXT,
    config_json     TEXT NOT NULL,
    collected_at    TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_gke_clusters_query_id ON gke_clusters(query_id);

CREATE TRIGGER IF NOT EXISTS keep_last_20_queries
AFTER INSERT ON queries
BEGIN
    DELETE FROM queries
    WHERE id NOT IN (
        SELECT id FROM queries ORDER BY id DESC LIMIT 20
    );
END;
"""


def connect_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path, check_same_thread=False)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
    return conn


def start_query(conn: sqlite3.Connection, folder_id: str, notes: str = "python scan") -> int:
    cur = conn.execute(
        "INSERT INTO queries (folder_id, notes) VALUES (?, ?)",
        (folder_id, notes),
    )
    conn.commit()
    return int(cur.lastrowid)


def insert_clusters(conn: sqlite3.Connection, query_id: int, rows: list[dict[str, Any]]) -> int:
    if not rows:
        return 0
    conn.executemany(
        """
        INSERT INTO gke_clusters (
            query_id, project_id, cluster_name, location, status,
            master_version, node_count, endpoint, config_json
        ) VALUES (
            :query_id, :project_id, :cluster_name, :location, :status,
            :master_version, :node_count, :endpoint, :config_json
        )
        """,
        rows,
    )
    conn.commit()
    return len(rows)


def collect_projects(folder_id: str) -> list[str]:
    """Recursively collect ACTIVE project IDs under folders/{folder_id}."""
    folders_client = resourcemanager_v3.FoldersClient()
    projects_client = resourcemanager_v3.ProjectsClient()
    found: set[str] = set()

    def recurse(parent: str) -> None:
        try:
            for project in projects_client.list_projects(parent=parent):
                if project.state == resourcemanager_v3.Project.State.ACTIVE:
                    found.add(project.project_id)
        except Exception as e:
            print(f"Warning: projects under {parent}: {e}")

        try:
            for folder in folders_client.list_folders(parent=parent):
                recurse(folder.name)
        except Exception as e:
            print(f"Warning: folders under {parent}: {e}")

    recurse(f"folders/{folder_id}")
    return sorted(found)


def _cluster_to_dict(cluster: Any) -> dict[str, Any]:
    if hasattr(cluster, "_pb"):
        from google.protobuf.json_format import MessageToDict
        return MessageToDict(cluster._pb, preserving_proto_field_name=False)
    if hasattr(cluster, "to_dict"):
        return cluster.to_dict()
    return json.loads(json.dumps(cluster, default=str))


def list_clusters_for_project(project_id: str) -> list[dict[str, Any]]:
    """List all clusters in a project (all locations)."""
    client = container_v1.ClusterManagerClient()
    parent = f"projects/{project_id}/locations/-"
    rows: list[dict[str, Any]] = []

    try:
        response = client.list_clusters(parent=parent)
        for cluster in response.clusters or []:
            raw = _cluster_to_dict(cluster)
            rows.append(
                {
                    "project_id": project_id,
                    "cluster_name": raw.get("name") or getattr(cluster, "name", None),
                    "location": raw.get("location") or getattr(cluster, "location", None),
                    "status": str(raw.get("status") or getattr(cluster, "status", "")),
                    "master_version": (
                        raw.get("currentMasterVersion")
                        or raw.get("current_master_version")
                        or getattr(cluster, "current_master_version", None)
                    ),
                    "node_count": (
                        raw.get("currentNodeCount")
                        or raw.get("current_node_count")
                        or getattr(cluster, "current_node_count", 0)
                        or 0
                    ),
                    "endpoint": raw.get("endpoint") or getattr(cluster, "endpoint", None),
                    "config_json": json.dumps(raw, default=str),
                }
            )
    except Exception as e:
        print(f"Warning: clusters in {project_id}: {e}")

    return rows


def collect_all_clusters(project_ids: list[str], workers: int) -> list[dict[str, Any]]:
    all_rows: list[dict[str, Any]] = []
    if not project_ids:
        return all_rows

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(list_clusters_for_project, p): p for p in project_ids}
        for fut in concurrent.futures.as_completed(futures):
            all_rows.extend(fut.result())
    return all_rows


def main() -> None:
    parser = argparse.ArgumentParser(description="Scan GKE clusters under a GCP folder")
    parser.add_argument("--folder-id", required=True, help="Numeric folder ID")
    parser.add_argument("--db", default="gke_history.db", help="SQLite path")
    parser.add_argument("--workers", type=int, default=8, help="Parallel project workers")
    parser.add_argument("--notes", default="python scan")
    args = parser.parse_args()

    print(f"Collecting projects under folder {args.folder_id}...")
    projects = collect_projects(args.folder_id)
    print(f"Found {len(projects)} project(s).")

    print(f"Listing clusters with {args.workers} workers...")
    cluster_rows = collect_all_clusters(projects, workers=args.workers)
    print(f"Found {len(cluster_rows)} cluster(s).")

    conn = connect_db(args.db)
    try:
        query_id = start_query(conn, args.folder_id, notes=args.notes)
        for r in cluster_rows:
            r["query_id"] = query_id
        n = insert_clusters(conn, query_id, cluster_rows)
        print(f"Saved query_id={query_id} with {n} row(s) → {args.db}")
        print("Retention: last 20 queries (trigger).")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
```

---

## 7. Useful follow-ups

**Inspect latest run**

```sql
SELECT id, created_at, folder_id, notes
FROM queries
ORDER BY id DESC
LIMIT 5;

SELECT project_id, cluster_name, location, status, master_version, node_count
FROM gke_clusters
WHERE query_id = (SELECT MAX(id) FROM queries);
```

**Auth**

```bash
gcloud auth login
gcloud auth application-default login
```

**Quotas**

Start with 4–8 parallel project workers. Increase only if you stay under Container API limits; add retry/backoff on `429` if needed.

---

## 8. Session decision log

1. **Recursive hierarchy + GKE describe** — CLI and Python samples.  
2. **SQLite history** — yes; keep last 20 queries via trigger (native enough).  
3. **Multithreading SQLite** — possible; performance impact negligible for this use case.  
4. **Multithread GCP?** — yes at **project** cluster-list level; keep folder walk simple.  
5. **More fields over time** — hybrid: stable columns + `config_json`; promote columns when needed.  
6. **Deliverable** — two full code sets (bash/`gcloud` and Python client libraries) plus shared schema.

---

*End of document.*
```

Save that block as `gcp-gke-folder-scan.md` (or similar). If you want it split into separate `.sh` / `.py` files plus a short README, say so and those can be formatted the same way.
