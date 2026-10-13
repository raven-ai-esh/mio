# Third-party acknowledgments

The Mio application code is covered by the root MIT license. The following components retain their original licenses and notices.

| Component | Included notices |
| --- | --- |
| SQLite with FTS5 | Public-domain provenance in Sources/CSQLite/PROVENANCE.md and the original source headers. |
| EmbeddingGemma2Swift runtime | Vendor/EmbeddingGemma2Swift/LICENSE (MIT) and NOTICE. |
| MLX and MLX-VLM dependencies | MIT; upstream notices are copied into the app, with the MLX-VLM notice also retained in Vendor/EmbeddingGemma2Swift/UPSTREAM_MLX_VLM_LICENSE. |
| EventSource and yyjson | MIT; upstream notices are copied into the app. |
| Swift utility and Hugging Face dependencies | Apache-2.0; upstream notices are copied into the app. See Vendor/EmbeddingGemma2Swift/APACHE-2.0.txt and the pinned Package.resolved. |
| Pillow-derived processor reference | Vendor/EmbeddingGemma2Swift/UPSTREAM_PILLOW_LICENSE (MIT-CMU). |

Upstream revisions and modifications are documented in Vendor/EmbeddingGemma2Swift/UPSTREAM.json. The packaging script includes the runtime/dependency licenses in the app's Resources/ThirdParty directory and the SQLite provenance notice.

Embedding model weights are downloaded separately, verified against the bundled manifest, and are not part of this source repository. Their upstream repository is identified in Sources/MioEmbeddings/ModelManifest.json. The root Mio license does not replace upstream model or dependency terms.

The demo text and diagrams are created for Mio. Screenshots show fictional demonstration memory. macOS supplies the system fonts used to render the interface; font binaries are not redistributed here.
