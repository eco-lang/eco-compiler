# RAG CLI

A command-line RAG (Retrieval-Augmented Generation) tool using OpenAI's vector store and file search.

## Installation

```bash
pip install rag-cli
# or with pipx (recommended for CLI tools)
pipx install rag-cli
```

## Setup

1. Set your OpenAI API key:
   ```bash
   export OPEN_AI_API_KEY="your-api-key"
   ```

2. Create a `knowledge/` directory and add your documents (`.txt`, `.md`, `.pdf`, `.py`, etc.)

3. Run the CLI:
   ```bash
   rag-cli
   ```

On first run, you'll be prompted to select a model and reasoning effort level.

## Usage

### Interactive Mode (default)

```bash
rag-cli
```

### Non-interactive Mode

```bash
echo "What is garbage collection?" | rag-cli -n
```

### Options

| Option | Description |
|--------|-------------|
| `--reindex` | Force re-upload and reindex all files |
| `--strict` | Only answer if information is in the indexed files |
| `--debug` | Show retrieved chunks from vector store |
| `-t`, `--thinking` | Override thinking level: `l`=low, `m`=medium, `h`=high |
| `-n`, `--non-interactive` | Read query from stdin, write response to stdout, exit |

## Supported File Types

- Documents: `.txt`, `.md`, `.pdf`, `.doc`, `.docx`, `.pptx`, `.html`
- Data: `.json`, `.xml`, `.csv`, `.yaml`
- Code: `.py`, `.js`, `.ts`, `.java`, `.c`, `.cpp`, `.go`, `.rs`, `.rb`, `.php`, `.sql`, `.sh`, `.elm`, `.hs`, and more
- Config: `.toml`, `.ini`, `.cfg`, `.conf`, `.tex`

## Development

```bash
# Clone and install in development mode
git clone https://github.com/rupertlssmith/rag-cli
cd rag-cli
pip install -e .
```

## License

MIT
