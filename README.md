# Ollama Direct Downloader

<p align="center">
  <img src="public/favicon_dark.png" alt="Ollama Logo" width="100" />
</p>

Downloading ollama models using `ollama pull model_name:tag` can be very slow and unreliable sometimes and in some regions. With this tool, you can get the direct download links for ollama models.

## How to use

1. Go to the [Ollama Direct Downloader](https://ollama-direct-downloader.vercel.app/) website.
2. Enter the model name and tag in the search bar. (e.g. `gemma2:2b`)
3. Click the "Extract" button.
4. Download the manifest file and place it in a folder like `$OLLAMA_MODELS\manifests\registry.ollama.ai\library\gemma2`
5. Download the blobs and place them in a folder like `$OLLAMA_MODELS\blobs`

NOTE: The server might change the name of each file, copy the names from the box above and rename the files accordingly.

## Screenshots

![Screenshot 1](images/demo_dark.png)

![Screenshot 2](images/demo_light.png)

## Stack

- React
- Next.js
- Tailwind CSS
- Vercel (CORS proxy api)
- Upstash KV store (Anonymous data is stored on the db for finding bugs)

## Urls

If you need to get the manifest file for a model for your own projects, follow these examples:

`gemma2:2b` model (note the `library/` path):
`https://registry.ollama.ai/v2/library/gemma2/manifests/2b`

`huihui_ai/deepseek-r1-abliterated:8b` model:
`https://registry.ollama.ai/v2/huihui_ai/deepseek-r1-abliterated/manifests/8b`


## PowerShell direct downloader

If you want to skip the web UI, use the script at `scripts/ollama-direct-download.ps1`.
It fetches the manifest + all blobs and puts them directly into the correct Ollama folders.

```powershell
# Download a model directly to $env:OLLAMA_MODELS (or ~/.ollama/models when env var is not set)
pwsh ./scripts/ollama-direct-download.ps1 gemma2:2b

# Optional: override models directory and increase concurrency
pwsh ./scripts/ollama-direct-download.ps1 llama3.2:latest -ModelsRoot "D:\ollama\models" -MaxConcurrency 12
```

Notes:
- For non-library models, include namespace in the model ref, for example: `huihui_ai/deepseek-r1-abliterated:8b`.
- Use `-Force` to re-download files even if they already exist.
- Use `-SkipManifest` if you only want missing blobs.

## Downloading from Huggingface

Alternatively we can download `.gguf` files from hugging face and convert them to ollama format with the following command:

```bash
ollama create myModelName -f Modelfile
ollama run myModelName
```

Visit [this link](https://github.com/ollama/ollama/blob/main/docs/modelfile.md) for instructions on creating a Modelfile. Also you can view a Modelfile for an existing model with:

```bash
ollama show --modelfile llama3.2
```

## License

This project is licensed under the MIT License.

By Gholamreza Dar 2025
