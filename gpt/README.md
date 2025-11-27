# RAG CLI

A command-line tool for building and querying a knowledge base using OpenAI's vector store and file search capabilities. RAG CLI lets you index your documents, code, and data files, then have natural conversations with an AI that can search and retrieve relevant information from your indexed content.

**Key features:**
- Index documents, code, and data files with a single command
- Interactive chat with context-aware responses from your knowledge base
- Non-interactive mode for scripting and automation
- Support for OpenAI's reasoning models with configurable thinking levels
- Strict mode to ensure answers come only from indexed content

## Prerequisites

- Python 3.10 or higher
- An OpenAI API key with access to the Responses API

## Installation

```bash
# Clone the repository
git clone https://github.com/the-sett/rag-cli.git
cd rag-cli

# Create and activate a virtual environment
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies and the package in development mode
./venv/bin/pip install -e .

# Symlink the program in working directory for convenience
ln -s ./venv/bin/rag-cli
```

## Configuration

### OpenAI API Key

RAG CLI requires an OpenAI API key. Set it as an environment variable:

```bash
export OPEN_AI_API_KEY="sk-your-api-key-here"
```

To make this permanent, add it to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.):

```bash
echo 'export OPEN_AI_API_KEY="sk-your-api-key-here"' >> ~/.bashrc
source ~/.bashrc
```

You can obtain an API key from [OpenAI's platform](https://platform.openai.com/api-keys).

### Settings File

On first run, RAG CLI creates a `settings.json` file in the current directory containing:
- `model` - Selected OpenAI model
- `reasoning_effort` - Thinking level (low/medium/high)
- `vector_store_id` - OpenAI vector store ID
- `file_patterns` - Indexed file patterns

This file is gitignored by default as it contains API-specific IDs.

## Usage

### Indexing Files

On first run, provide files or glob patterns to index:

```bash
# Index specific files
rag-cli README.md docs/guide.md

# Index with glob patterns
rag-cli 'docs/*.md'

# Index recursively
rag-cli 'docs/**/*.md'

# Index multiple patterns
rag-cli 'docs/**/*.md' 'src/**/*.py' '*.txt'

# Index a directory (all supported files)
rag-cli knowledge/
```

You'll be prompted to select a model and reasoning effort level.

### Interactive Chat

Once indexed, run without arguments to start chatting:

```bash
rag-cli
```

Type your questions and the AI will search your indexed files for relevant context. Type `quit` or `exit` to end the session.

### Re-indexing

To update your knowledge base with new or changed files:

```bash
rag-cli --reindex 'docs/**/*.md'
```

### Non-interactive Mode

For scripting and automation, use non-interactive mode:

```bash
echo "What is garbage collection?" | rag-cli -n
```

This reads the query from stdin, outputs the response to stdout, and exits.

### Command-Line Options

| Option | Description |
|--------|-------------|
| `FILE ...` | Files or glob patterns to index |
| `--reindex` | Force re-upload and reindex files |
| `--strict` | Only answer if information is in the indexed files |
| `--debug` | Show retrieved chunks from vector store |
| `-t`, `--thinking` | Override thinking level: `l`=low, `m`=medium, `h`=high |
| `-n`, `--non-interactive` | Read query from stdin, write response to stdout, exit |

### Glob Pattern Examples

| Pattern | Matches |
|---------|---------|
| `*.md` | All markdown files in current directory |
| `docs/*.md` | All markdown files in docs/ |
| `docs/**/*.md` | All markdown files in docs/ recursively |
| `src/**/*.py` | All Python files in src/ recursively |
| `*.{md,txt}` | All .md and .txt files (shell expansion) |

## Supported File Types

RAG CLI supports a wide range of file types:

- **Documents**: `.txt`, `.md`, `.pdf`, `.doc`, `.docx`, `.pptx`, `.html`
- **Data**: `.json`, `.xml`, `.csv`, `.yaml`, `.yml`
- **Code**: `.py`, `.js`, `.ts`, `.jsx`, `.tsx`, `.java`, `.c`, `.cpp`, `.h`, `.hpp`, `.cs`, `.go`, `.rs`, `.rb`, `.php`, `.swift`, `.kt`, `.scala`, `.r`, `.sh`, `.bash`, `.sql`, `.lua`, `.pl`, `.hs`, `.elm`, `.ex`, `.clj`, `.lisp`, `.ml`, `.fs`
- **Config**: `.toml`, `.ini`, `.cfg`, `.conf`, `.tex`, `.rst`, `.org`

## Development

### Project Structure

```
rag-cli/
├── src/
│   └── rag_cli/
│       ├── __init__.py
│       └── main.py      # Main CLI implementation
├── pyproject.toml       # Project configuration and dependencies
├── README.md
└── .gitignore
```

### Running Locally

After installing, you can run the CLI via the virtual environment:

```bash
./venv/bin/rag-cli 'docs/*.md'
```

Or activate the virtual environment first:

```bash
source venv/bin/activate
rag-cli 'docs/*.md'
```

## License

MIT
