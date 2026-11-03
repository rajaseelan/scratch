To execute this vibe coding strategy effectively using VS Code and GitHub Copilot, you need to combine Copilot Chat (Workspace context), Copilot Edits (multi-file editing mode), and a strict project structure.
Because Copilot works best when it can read clear, explicit architecture guidelines, your first step is setting up the environment to control how the AI behaves.

1. Set Up Your VS Code System Prompts

VS Code and GitHub Copilot allow you to define persistent instructions for your workspace. This prevents you from having to repeat your core guidelines (Python 3.13, uv, no-disk writes) in every prompt.
1. In your project root, create a file named .github/copilot-instructions.md.
2. Paste the following configuration directly into it:
markdown
# GitHub Copilot Instructions for GCP Secret Manager Uploader

## Technology Stack
- Runtime: Python 3.13+ (Use modern typing structures, native generic syntax, and async def).
- Package Manager: Managed exclusively via `uv` (`uv pip`, `uv add`, inline script metadata).
- Frameworks: FastAPI, SQLModel, LangGraph.
- Hosting: GKE (Kubernetes Service Account / Workload Identity).

## Architecture & Code Constraints
- Files must be short, modular, and single-responsibility. Do not exceed 200 lines per file.
- All database operations must use SQLModel and remain agnostic (work on both SQLite and PostgreSQL).
- CRITICAL SECURITY: Never write uploaded or downloaded secret payloads to the local filesystem or disk. Use `io.BytesIO` to manipulate secret bytes purely in memory.
Use code with caution.

2. Leverage "Copilot Edits" for Multi-File Implementation

Do not use the standard inline chat (Ctrl+I) or general sidebar chat for building the entire architecture. Use Copilot Edits (Ctrl+Shift+I or Cmd+Shift+I on Mac), which allows Copilot to act as an agent that modifies multiple files simultaneously while understanding their relationships.

Step 1: Initialize the Project with uv

Open your VS Code terminal and initialize your Python 3.13 project instantly using uv:
bash
uv init --app
uv add fastapi sqlmodel langgraph google-cloud-secret-manager uvicorn asyncpg
Use code with caution.

Step 2: Prompting Strategy for the Core Code

Open Copilot Edits, add your newly generated files to the working context, and prompt step-by-step:
• Prompt 1 (Database & Models):"@workspace Create models.py with SQLModel definitions for tracking secret upload/download jobs (fields for project_id, secret_endpoint, sha256sum, gcp_path, timestamp). Create database.py that checks os.getenv('DATABASE_URL')—if it starts with 'sqlite', configure an SQLite engine with connect_args={"check_same_thread": False}, otherwise configure an async PostgreSQL engine using asyncpg."
• Prompt 2 (In-Memory GCP Logic):"@workspace Create gcp_service.py to handle google-cloud-secret-manager. Write async methods for uploading and downloading secrets. Ensure it reads bytes directly from an incoming stream into memory (io.BytesIO) and computes the hashlib.sha256 checksum without writing anything to disk."
• Prompt 3 (LangGraph State Machine):"@workspace Create workflow.py using LangGraph to manage the state. The state machine should track steps: [VALIDATE, GCP_OPERATE, DB_LOG]. Use an in-memory checkpointer to keep the workflow resumable as required."
• Prompt 4 (FastAPI Routing):"@workspace Create main.py configuring the FastAPI app. Build two endpoints: POST /secrets/upload (accepts file upload, project_id, endpoint, optional GCP Token header) and POST /secrets/fetch. Both endpoints must execute the LangGraph workflow and return the resulting state payload."

3. Containerise and Test via VS Code Terminal

Once Copilot Edits completes your python files, add your Docker configuration.
• Prompt for Dockerfile:"Create a multi-stage Dockerfile optimized for Python 3.13 using uv. Stage 1 should synchronize dependencies using uv sync --frozen. Stage 2 should be a minimal python runtime copying only the virtual environment (.venv) to run the FastAPI app via uvicorn."
To run and verify your backend locally using uv before containerising:
bash
# Run local SQLite test instance
DATABASE_URL=sqlite:///database.db uv run uvicorn main:app --reload
Use code with caution.

4. Golden Rules for Using Copilot Sustainably

• Keep Files Open: Copilot gives highest priority context to the files currently open in your active VS Code tabs. Keep models.py and database.py open when generating your routing logic so it infers dependencies correctly.
• Reject Sweeping Hallucinations: If Copilot edits a file and breaks existing functionality, use the "Undo" button inside the Copilot Edits panel immediately. Do not try to write a secondary prompt to fix a bad generation; revert to your last working state and break your prompt into a smaller sub-task.
• Utilise Terminal Diagnostic Fixes: If a run command fails in your terminal, hover over the error or select it, right-click, and choose "Explain with Copilot" or click the Copilot sparkle icon directly in the terminal panel to instantly diagnose Python 3.13 or dependency discrepancies.
Would you like to generate the .github/copilot-instructions.md configuration file and the atomic models.py structural layout right now to kick off your workspace?
