# nano banana 이미지 생성 프롬프트

> llm-wiki-mcp PPT용. Pillow로는 다이어그램(노드·박스)만 생성 가능하므로,
> 사실적 히어로/일러스트가 필요한 슬라이드는 아래 프롬프트를 nano banana(또는
> 동급 이미지 생성 모델)에 넣어 생성한 뒤 `docs/img/` 에 두고 빌드 스크립트의
> `GRAPH_PNG` 자리에 교체/추가하면 된다.
>
> 공통 스타일 토큰(docs/DESIGN-apple.md 준수):
> - 배경: 순백 `#FFFFFF` 또는 parchment off-white `#F5F5F7`
> - 단일 액센트: Action Blue `#0066CC` (두 번째 브랜드색 금지)
> - 텍스트/잉크: Near-Black `#1D1D1F`, 보조회색 `#6E6E73`
> - 선: hairline `#D2D2D7`, 그림자 없음(평면), 둥근 모서리(pill/large radius)
> - 폰트 느낌: SF Pro / Apple SD Gothic Neo, 여백 과다

---

## 1. 표지 히어로 — 지식 네트워크 추상 (Cover)

```
Minimalist Apple-style hero illustration on a soft parchment off-white
(#F5F5F7) background. A serene constellation of small glowing nodes
connected by whisper-thin hairline edges (#D2D2D7), forming an organic
knowledge graph. Exactly one accent color: calm Apple Action Blue
(#0066CC) used only on a few key hub nodes; all other nodes are near-black
(#1D1D1F) dots. No gradients, no drop shadows, no decorative borders.
Massive negative space, museum-gallery calm. Ultra-clean, flat vector
aesthetic, 16:9, soft ambient light. Inspired by Apple keynote product
tiles.
```

## 2. Obsidian Graph View — 노드-링크 일러스트

```
A clean knowledge-graph visualization in Obsidian's Graph View style,
rendered with Apple's restrained design language. Soft white (#FFFFFF)
canvas. One large central hub node in Apple Action Blue (#0066CC),
surrounded by ~8 smaller satellite nodes in a brighter sky-blue (#2997FF),
each labeled with a short lowercase kebab-case English word (monitoring,
drift, metrics, rag, ingest, ocr, tools, infra). Nodes connected by thin
semi-transparent gray hairlines. No shadows, no glow, no 3D. Flat, crisp,
typographic labels in SF Pro. Generous whitespace, 16:9, high-DPI vector
feel. Calm, editorial, technical-but-beautiful.
```

## 3. 데이터 흐름 아키텍처 — raw → wiki → 검색

```
A flat minimalist architecture diagram in Apple design language on a
parchment off-white (#F5F5F7) background. Three stages left to right,
connected by a single thin hairline flow: (1) a "raw" stack of source
documents, (2) a central "wiki" markdown-notes folder, (3) a search/index
panel. Each stage is a rounded-corner card (large radius) with a single
Apple Action Blue (#0066CC) icon and a short label. Near-black (#1D1D1F)
text, muted-gray (#6E6E73) sublabels. No drop shadows, no gradients, no
borders on cards — separation comes only from whitespace and a faint
hairline divider. Tasteful, spacious, 16:9, SF Pro typography.
```

---

### 적용 방법
1. 위 프롬프트 중 하나로 nano banana에서 이미지 생성.
2. 결과 PNG를 `docs/img/wiki-graph.png`로 덮어쓰거나 새 파일(예: `cover-hero.png`)로 저장.
3. `build_wiki_mcp_ppt_apple.py` 의 `GRAPH_PNG` 경로 또는 `add_picture` 호출부를 해당 파일로 지정 후 재실행.
