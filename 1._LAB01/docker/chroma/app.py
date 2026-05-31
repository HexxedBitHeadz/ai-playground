import os
from typing import List, Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import chromadb
from chromadb.utils.embedding_functions import SentenceTransformerEmbeddingFunction

app = FastAPI(title="Chroma RAG Service")

persist_directory = os.getenv("CHROMA_PERSIST_DIR", "/data")
client = chromadb.PersistentClient(path=persist_directory)
embedding_fn = SentenceTransformerEmbeddingFunction(model_name="all-MiniLM-L6-v2")
collection = client.get_or_create_collection(name="documents", embedding_function=embedding_fn)


class Document(BaseModel):
    id: str
    text: str
    metadata: Optional[dict] = {}


class QueryRequest(BaseModel):
    query: str
    top_k: int = 5


@app.get("/health")
def health():
    return {"status": "ok", "collection_size": collection.count()} 


@app.post("/ingest")
def ingest(documents: List[Document]):
    if not documents:
        raise HTTPException(status_code=400, detail="No documents provided")

    ids = [doc.id for doc in documents]
    texts = [doc.text for doc in documents]
    metadatas = [doc.metadata or {} for doc in documents]

    collection.upsert(ids=ids, documents=texts, metadatas=metadatas)
    return {"ingested": len(ids), "ids": ids}


@app.post("/query")
def query(payload: QueryRequest):
    if not payload.query:
        raise HTTPException(status_code=400, detail="Query text required")

    results = collection.query(query_texts=[payload.query], n_results=payload.top_k)
    hits = []
    for idx, doc_id in enumerate(results["ids"][0]):
        hits.append({
            "id": doc_id,
            "text": results["documents"][0][idx],
            "metadata": results["metadatas"][0][idx],
            "distance": results["distances"][0][idx],
        })

    return {"query": payload.query, "results": hits}


@app.get("/documents")
def list_documents():
    return {"count": collection.count(), "ids": collection.get(include=["ids"]) ["ids"]}
