import os
import sys
import json
import time
import argparse
from datetime import datetime
from openai import OpenAI
from rich.console import Console
from rich.status import Status
from rich.prompt import Prompt

# --------------------------------
# Config
# --------------------------------

DOCS_DIR = "knowledge"
SETTINGS_FILE = "settings.json"
LOG_DIR = "chat_logs"

console = Console()

api_key = os.environ.get("OPEN_AI_API_KEY")
if not api_key:
    console.print("[red]Error: OPEN_AI_API_KEY environment variable not set[/red]")
    sys.exit(1)

client = OpenAI(api_key=api_key)

os.makedirs(LOG_DIR, exist_ok=True)

# --------------------------------
# CLI Args
# --------------------------------

parser = argparse.ArgumentParser()
parser.add_argument("--reindex", action="store_true", help="Force re-upload + reindex")
parser.add_argument("--strict", action="store_true", help="Only answer if info is in files")
parser.add_argument("--debug", action="store_true", help="Show retrieved chunks")
args = parser.parse_args()

# --------------------------------
# Settings Management
# --------------------------------

def load_settings():
    if os.path.exists(SETTINGS_FILE):
        with open(SETTINGS_FILE, "r") as f:
            return json.load(f)
    return {}

def save_settings(settings):
    with open(SETTINGS_FILE, "w") as f:
        json.dump(settings, f, indent=2)

def select_model():
    console.print("\n[yellow]Fetching available models...[/yellow]")

    with Status("[yellow]Loading models from OpenAI...[/yellow]", console=console):
        models = client.models.list()

    # Filter to gpt-5* models only
    chat_models = sorted([
        m.id for m in models.data
        if m.id.startswith("gpt-5")
    ])

    if not chat_models:
        console.print("[red]No chat models found![/red]")
        sys.exit(1)

    console.print("\n[bold cyan]Available models:[/bold cyan]")
    for i, model in enumerate(chat_models, 1):
        console.print(f"  {i:2}. {model}")

    console.print()
    while True:
        choice = Prompt.ask("Select model number", default="1")
        try:
            idx = int(choice) - 1
            if 0 <= idx < len(chat_models):
                selected = chat_models[idx]
                console.print(f"[green]✓[/green] Selected: {selected}")
                return selected
        except ValueError:
            pass
        console.print("[red]Invalid choice, try again[/red]")

# --------------------------------
# Load or create vector store
# --------------------------------

def load_or_create_settings():
    """Load existing settings or run first-time setup."""
    settings = load_settings()
    needs_setup = args.reindex or not settings.get("vector_store_id")

    if not needs_setup:
        console.print(f"[green]Using model:[/green] {settings.get('model')}")
        console.print(f"[green]Using vector store:[/green] {settings.get('vector_store_id')}")
        return settings

    # First time or reindex - select model and create vector store
    settings["model"] = select_model()
    settings["vector_store_id"] = create_vector_store()
    save_settings(settings)
    return settings

def create_vector_store():
    """Upload files and create a new vector store."""
    console.print("\n[yellow]Uploading and indexing files...[/yellow]")

    file_ids = []

    # File types supported by OpenAI's file_search
    SUPPORTED_EXTENSIONS = (
        # Documents
        ".txt", ".md", ".pdf", ".doc", ".docx", ".pptx", ".html", ".htm",
        # Data formats
        ".json", ".xml", ".csv", ".tsv", ".yaml", ".yml",
        # Programming languages
        ".py", ".js", ".ts", ".jsx", ".tsx", ".java", ".c", ".cpp", ".h", ".hpp",
        ".cs", ".go", ".rs", ".rb", ".php", ".swift", ".kt", ".scala", ".r",
        ".sh", ".bash", ".zsh", ".ps1", ".bat", ".cmd", ".sql", ".lua", ".pl",
        ".hs", ".elm", ".ex", ".exs", ".clj", ".lisp", ".scm", ".ml", ".fs",
        # Config and markup
        ".toml", ".ini", ".cfg", ".conf", ".tex", ".rst", ".org", ".adoc",
    )

    files_to_upload = [f for f in os.listdir(DOCS_DIR) if f.lower().endswith(SUPPORTED_EXTENSIONS)]
    total_files = len(files_to_upload)

    for i, filename in enumerate(files_to_upload, 1):
        path = os.path.join(DOCS_DIR, filename)

        with Status(f"[yellow]Uploading ({i}/{total_files}): {filename}[/yellow]", console=console):
            with open(path, "rb") as f:
                uploaded = client.files.create(
                    file=f,
                    purpose="assistants"
                )

        file_ids.append(uploaded.id)
        console.print(f"  [green]✓[/green] ({i}/{total_files}) {filename}")

    if not file_ids:
        console.print("[red]Error: No supported files found in knowledge/ directory[/red]")
        console.print("Supported: documents, code files, data formats (txt, md, pdf, py, js, json, etc.)")
        sys.exit(1)

    console.print("\n[yellow]Creating vector store...[/yellow]")
    vector_store = client.vector_stores.create(
        name="cli-rag-store"
    )
    console.print(f"[green]✓[/green] Vector store created: {vector_store.id}")

    console.print("[yellow]Starting batch indexing...[/yellow]")
    batch = client.vector_stores.file_batches.create(
        vector_store_id=vector_store.id,
        file_ids=file_ids
    )

    with Status(f"[yellow]Indexing {total_files} files (this may take a minute)...[/yellow]", console=console):
        while True:
            batch_status = client.vector_stores.file_batches.retrieve(
                vector_store_id=vector_store.id,
                batch_id=batch.id
            )
            if batch_status.status == "completed":
                break
            if batch_status.status == "failed":
                console.print("[red]Error: Vector store indexing failed[/red]")
                sys.exit(1)
            time.sleep(1)

    console.print("[green]✓ Vector store ready.[/green]")
    return vector_store.id

def main():
    settings = load_or_create_settings()
    model = settings["model"]
    vector_store_id = settings["vector_store_id"]

    # --------------------------------
    # System Prompt (Strict mode aware)
    # --------------------------------

    system_prompt = (
        "You are a specialized assistant. "
        "Use ONLY the provided file knowledge when relevant. "
    )

    if args.strict:
        system_prompt += (
            "If the answer is not explicitly contained in the files, "
            "respond with: 'The provided documents do not contain that information.'"
        )
    else:
        system_prompt += (
            "If the files do not contain the answer, you may reason normally but clearly "
            "state that you are extrapolating."
        )

    conversation = [
        {"role": "system", "content": system_prompt}
    ]

    # --------------------------------
    # Logging
    # --------------------------------

    log_path = os.path.join(
        LOG_DIR, f"chat_{datetime.now().strftime('%Y%m%d_%H%M%S')}.md"
    )

    def log(role, text):
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(f"## {role.upper()}\n{text}\n\n")

    # --------------------------------
    # Streaming Chat Loop
    # --------------------------------

    console.print("\n[bold cyan]=== RAG CLI Ready ===[/bold cyan]")
    console.print("Type 'quit' to exit.\n")

    while True:
        user_input = input("You: ").strip()

        if user_input.lower() in {"quit", "exit"}:
            console.print("Goodbye.")
            break

        conversation.append({"role": "user", "content": user_input})
        log("user", user_input)

        console.print("\n[bold green]Assistant:[/bold green]")

        streamed_text = []

        response = client.responses.create(
            model=model,
            input=conversation,
            stream=True,
            tools=[
                {
                    "type": "file_search",
                    "vector_store_ids": [vector_store_id]
                }
            ]
        )

        retrieved_chunks = []

        for event in response:
            if event.type == "response.output_text.delta":
                console.print(event.delta, end="")
                streamed_text.append(event.delta)

            elif event.type == "response.file_search.result" and args.debug:
                retrieved_chunks.append(event)

        final_answer = "".join(streamed_text)

        conversation.append({"role": "assistant", "content": final_answer})
        log("assistant", final_answer)

        console.print("\n")

        # --------------------------------
        # Debug: show retrieved chunks
        # --------------------------------

        if args.debug and retrieved_chunks:
            console.print("\n[bold yellow]--- Retrieved Chunks ---[/bold yellow]")
            for chunk in retrieved_chunks:
                console.print(chunk)
            console.print("--------------------------------\n")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        console.print("\n[yellow]Interrupted.[/yellow]")
        sys.exit(0)

