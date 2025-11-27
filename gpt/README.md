# RAG CLI

A command-line RAG (Retrieval-Augmented Generation) tool using OpenAI's vector store and file search.

## Installation

```bash
pip install rag-cli
# or with pipx (recommended for CLI tools)
pipx install rag-cli
```

## Setup

Set your OpenAI API key:
```bash
export OPEN_AI_API_KEY="your-api-key"
```

## Usage

### First Run - Index Your Files

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

On first run, you'll be prompted to select a model and reasoning effort level.

### Subsequent Runs

Once indexed, just run without arguments to start chatting:
```bash
rag-cli
```

### Re-index Files

```bash
rag-cli --reindex 'new_docs/**/*.md'
```

### Non-interactive Mode

```bash
echo "What is garbage collection?" | rag-cli -n
```

### Options

| Option | Description |
|--------|-------------|
| `FILE ...` | Files or glob patterns to index |
| `--reindex` | Force re-upload and reindex files |
| `--strict` | Only answer if information is in the indexed files |
| `--debug` | Show retrieved chunks from vector store |
| `-t`, `--thinking` | Override thinking level: `l`=low, `m`=medium, `h`=high |
| `-n`, `--non-interactive` | Read query from stdin, write response to stdout, exit |

## Supported File Types

- **Documents**: `.txt`, `.md`, `.pdf`, `.doc`, `.docx`, `.pptx`, `.html`
- **Data**: `.json`, `.xml`, `.csv`, `.yaml`
- **Code**: `.py`, `.js`, `.ts`, `.java`, `.c`, `.cpp`, `.go`, `.rs`, `.rb`, `.php`, `.sql`, `.sh`, `.elm`, `.hs`, and more
- **Config**: `.toml`, `.ini`, `.cfg`, `.conf`, `.tex`

## Glob Pattern Examples

| Pattern | Matches |
|---------|---------|
| `*.md` | All markdown files in current directory |
| `docs/*.md` | All markdown files in docs/ |
| `docs/**/*.md` | All markdown files in docs/ recursively |
| `src/**/*.py` | All Python files in src/ recursively |
| `*.{md,txt}` | All .md and .txt files (shell expansion) |

## Settings

Settings are stored in `settings.json`:
- `model` - Selected OpenAI model
- `reasoning_effort` - Thinking level (low/medium/high)
- `vector_store_id` - OpenAI vector store ID
- `file_patterns` - Indexed file patterns

## Development

```bash
# Clone and install in development mode
git clone https://github.com/rupertlssmith/rag-cli
cd rag-cli
pip install -e .
```

## License

MIT
