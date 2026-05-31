import os
import requests

BASE_URL = os.getenv("CHROMA_URL", "http://localhost:8001")
INGEST_ENDPOINT = f"{BASE_URL}/ingest"
QUERY_ENDPOINT = f"{BASE_URL}/query"

SAMPLE_DOCS = [
    {
        "id": "doc-001",
        "text": "The local stack uses Ollama for model serving, a custom FastAPI WebUI, and a Chroma vector store for retrieval.",
        "metadata": {"source": "architecture"},
    },
    {
        "id": "doc-002",
        "text": "Chroma stores text embeddings and allows retrieval by similarity for RAG workflows.",
        "metadata": {"source": "rag"},
    },
    {
        "id": "doc-003",
        "text": "Prompt injection vectors include direct instruction overrides, persona jailbreaks, and indirect attacks embedded in documents the model reads.",
        "metadata": {"source": "security"},
    },
]


def ingest_documents():
    print(f"Ingesting {len(SAMPLE_DOCS)} documents into Chroma at {INGEST_ENDPOINT}")
    response = requests.post(INGEST_ENDPOINT, json=SAMPLE_DOCS, timeout=30)
    response.raise_for_status()
    print("Ingest response:", response.json())


def query_documents(query_text: str, top_k: int = 3):
    payload = {"query": query_text, "top_k": top_k}
    print(f"Querying Chroma with: {query_text}")
    response = requests.post(QUERY_ENDPOINT, json=payload, timeout=30)
    response.raise_for_status()
    result = response.json()
    print("Query results:")
    for item in result.get("results", []):
        print(f"- {item['id']} ({item['distance']:.4f}): {item['text']}")
    return result


if __name__ == "__main__":
    ingest_documents()
    query_documents("How does the local stack store documents for RAG?")
