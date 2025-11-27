import os
import sys
import json
import time
import glob
import argparse
from datetime import datetime
from openai import OpenAI
from rich.console import Console
from rich.status import Status
from rich.prompt import Prompt

# --------------------------------
# Config
# --------------------------------

SETTINGS_FILE = "settings.json"
LOG_DIR = "chat_logs"

THINKING_MAP = {"l": "low", "m": "medium", "h": "high"}

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

def select_model(client, console):
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

def select_reasoning_effort(console):
    """Select reasoning effort level for thinking models."""
    console.print("\n[bold cyan]Reasoning effort levels:[/bold cyan]")
    options = [
        ("low", "Minimal thinking - faster, cheaper"),
        ("medium", "Balanced thinking"),
        ("high", "Maximum thinking - slower, more thorough"),
    ]

    for i, (level, desc) in enumerate(options, 1):
        console.print(f"  {i}. {level:8} - {desc}")

    console.print()
    while True:
        choice = Prompt.ask("Select reasoning effort", default="2")
        try:
            idx = int(choice) - 1
            if 0 <= idx < len(options):
                selected = options[idx][0]
                console.print(f"[green]✓[/green] Selected: {selected}")
                return selected
        except ValueError:
            pass
        console.print("[red]Invalid choice, try again[/red]")

# --------------------------------
# File Resolution
# --------------------------------

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

def resolve_file_patterns(patterns, console):
    """Resolve glob patterns to a list of files."""
    files = []
    for pattern in patterns:
        # Expand glob pattern
        matches = glob.glob(pattern, recursive=True)
        if not matches:
            # Check if it's a literal file that doesn't exist
            if not any(c in pattern for c in '*?[]'):
                console.print(f"[yellow]Warning: File not found: {pattern}[/yellow]")
            else:
                console.print(f"[yellow]Warning: No matches for pattern: {pattern}[/yellow]")
            continue

        for match in matches:
            if os.path.isfile(match):
                # Check if it's a supported file type
                if match.lower().endswith(SUPPORTED_EXTENSIONS):
                    files.append(match)
                else:
                    console.print(f"[yellow]Warning: Unsupported file type: {match}[/yellow]")
            elif os.path.isdir(match):
                # If a directory is specified, get all supported files in it
                for root, _, filenames in os.walk(match):
                    for filename in filenames:
                        filepath = os.path.join(root, filename)
                        if filepath.lower().endswith(SUPPORTED_EXTENSIONS):
                            files.append(filepath)

    # Remove duplicates while preserving order
    seen = set()
    unique_files = []
    for f in files:
        abs_path = os.path.abspath(f)
        if abs_path not in seen:
            seen.add(abs_path)
            unique_files.append(f)

    return unique_files

# --------------------------------
# Vector Store Management
# --------------------------------

def create_vector_store(file_patterns, client, console):
    """Upload files and create a new vector store."""

    # Resolve file patterns to actual files
    files_to_upload = resolve_file_patterns(file_patterns, console)

    if not files_to_upload:
        console.print("[red]Error: No supported files found[/red]")
        console.print("\nUsage: rag-cli 'docs/*.md' 'src/**/*.py'")
        console.print("Supported: .txt, .md, .pdf, .py, .js, .json, .yaml, and many more")
        sys.exit(1)

    console.print(f"\n[yellow]Uploading {len(files_to_upload)} files...[/yellow]")

    file_ids = []
    total_files = len(files_to_upload)

    for i, filepath in enumerate(files_to_upload, 1):
        display_name = os.path.basename(filepath)

        with Status(f"[yellow]Uploading ({i}/{total_files}): {display_name}[/yellow]", console=console):
            with open(filepath, "rb") as f:
                uploaded = client.files.create(
                    file=f,
                    purpose="assistants"
                )

        file_ids.append(uploaded.id)
        console.print(f"  [green]✓[/green] ({i}/{total_files}) {filepath}")

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

def load_or_create_settings(args, client, console):
    """Load existing settings or run first-time setup."""
    settings = load_settings()
    needs_setup = args.reindex or not settings.get("vector_store_id")

    if not needs_setup:
        if not args.non_interactive:
            console.print(f"[green]Using model:[/green] {settings.get('model')}")
            if settings.get("reasoning_effort"):
                console.print(f"[green]Reasoning effort:[/green] {settings.get('reasoning_effort')}")
            console.print(f"[green]Using vector store:[/green] {settings.get('vector_store_id')}")
            if settings.get("file_patterns"):
                console.print(f"[green]Indexed patterns:[/green] {', '.join(settings['file_patterns'])}")
        return settings

    # Check if file patterns are provided
    if not args.files:
        console.print("[red]Error: No files specified for indexing[/red]")
        console.print("\nUsage: rag-cli 'docs/*.md' 'src/**/*.py'")
        console.print("       rag-cli --reindex 'knowledge/'")
        console.print("\nExamples:")
        console.print("  rag-cli '*.md'                    # All markdown files in current dir")
        console.print("  rag-cli 'docs/**/*.txt'           # All txt files in docs/ recursively")
        console.print("  rag-cli README.md guide.md        # Specific files")
        console.print("  rag-cli knowledge/                # All supported files in a directory")
        sys.exit(1)

    # First time or reindex - select model, reasoning, and create vector store
    settings["model"] = select_model(client, console)
    settings["reasoning_effort"] = select_reasoning_effort(console)
    settings["file_patterns"] = args.files
    settings["vector_store_id"] = create_vector_store(args.files, client, console)
    save_settings(settings)
    return settings

# --------------------------------
# Main Entry Point
# --------------------------------

def cli():
    """Main entry point for the CLI."""
    parser = argparse.ArgumentParser(
        prog="rag-cli",
        description="A RAG CLI tool using OpenAI's vector store and file search",
        epilog="Examples:\n"
               "  rag-cli 'docs/*.md'              Index markdown files and start chat\n"
               "  rag-cli 'src/**/*.py' '*.md'     Index multiple patterns\n"
               "  rag-cli --reindex 'knowledge/'  Re-index a directory\n"
               "  rag-cli                          Use existing index\n",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("files", nargs="*", metavar="FILE", help="Files or glob patterns to index (e.g., '*.md', 'docs/**/*.txt')")
    parser.add_argument("--reindex", action="store_true", help="Force re-upload + reindex files")
    parser.add_argument("--strict", action="store_true", help="Only answer if info is in files")
    parser.add_argument("--debug", action="store_true", help="Show retrieved chunks")
    parser.add_argument("-t", "--thinking", choices=["l", "m", "h"], help="Override thinking level: l=low, m=medium, h=high")
    parser.add_argument("-n", "--non-interactive", action="store_true", help="Non-interactive mode: read query from stdin, write response to stdout, exit")
    args = parser.parse_args()

    console = Console()

    # Check for API key
    api_key = os.environ.get("OPEN_AI_API_KEY")
    if not api_key:
        console.print("[red]Error: OPEN_AI_API_KEY environment variable not set[/red]")
        sys.exit(1)

    client = OpenAI(api_key=api_key)

    os.makedirs(LOG_DIR, exist_ok=True)

    try:
        main(args, client, console)
    except KeyboardInterrupt:
        console.print("\n[yellow]Interrupted.[/yellow]")
        sys.exit(0)

def main(args, client, console):
    """Main application logic."""
    settings = load_or_create_settings(args, client, console)
    model = settings["model"]
    vector_store_id = settings["vector_store_id"]

    # CLI override for thinking level
    if args.thinking:
        reasoning_effort = THINKING_MAP[args.thinking]
        if not args.non_interactive:
            console.print(f"[yellow]Thinking level override:[/yellow] {reasoning_effort}")
    else:
        reasoning_effort = settings.get("reasoning_effort")

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
    # Query Processing
    # --------------------------------

    def process_query(user_input):
        """Process a single query and return the response."""
        conversation.append({"role": "user", "content": user_input})
        log("user", user_input)

        streamed_text = []

        # Build API request
        request_kwargs = {
            "model": model,
            "input": conversation,
            "stream": True,
            "tools": [
                {
                    "type": "file_search",
                    "vector_store_ids": [vector_store_id]
                }
            ]
        }
        if reasoning_effort:
            request_kwargs["reasoning"] = {"effort": reasoning_effort}

        response = client.responses.create(**request_kwargs)

        retrieved_chunks = []

        for event in response:
            if event.type == "response.output_text.delta":
                if args.non_interactive:
                    print(event.delta, end="", flush=True)
                else:
                    console.print(event.delta, end="")
                streamed_text.append(event.delta)

            elif event.type == "response.file_search.result" and args.debug:
                retrieved_chunks.append(event)

        final_answer = "".join(streamed_text)

        conversation.append({"role": "assistant", "content": final_answer})
        log("assistant", final_answer)

        return final_answer, retrieved_chunks

    # --------------------------------
    # Non-interactive mode
    # --------------------------------

    if args.non_interactive:
        user_input = sys.stdin.read().strip()
        if not user_input:
            sys.exit(0)
        process_query(user_input)
        print()  # Final newline
        sys.exit(0)

    # --------------------------------
    # Interactive Chat Loop
    # --------------------------------

    console.print("\n[bold cyan]=== RAG CLI Ready ===[/bold cyan]")
    console.print("Type 'quit' to exit.\n")

    while True:
        user_input = input("You: ").strip()

        if user_input.lower() in {"quit", "exit"}:
            console.print("Goodbye.")
            break

        console.print("\n[bold green]Assistant:[/bold green]")

        _, retrieved_chunks = process_query(user_input)

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
    cli()
