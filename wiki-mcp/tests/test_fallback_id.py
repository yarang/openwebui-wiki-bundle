"""frontmatter id 없는 노트의 filename-stem fallback — Foam 워크플로 지원 (0.2.5).

VS Code Foam 확장은 끊어진 [[some-id]] 클릭으로 frontmatter id 없는 some-id.md 를
만든다. 이전에는 이런 노트가 조용히 인덱스에서 빠져 검색·그래프 어디에도 안 보였다.
frontmatter id 는 항상 우선이고, 없으면 파일 이름 stem 을 id 로 쓴다 (충돌 시 스킵+경고).
"""
from __future__ import annotations

from pathlib import Path

import frontmatter

from wiki_mcp import writer
from wiki_mcp.graph import WikiGraph
from wiki_mcp.indexer import WikiIndexer


def _ix(wiki: Path, tmp_path: Path) -> WikiIndexer:
    """BM25-only 인덱서 — 저장소·임베딩 서버 없이 (기존 테스트의 store=False 스타일)."""
    return WikiIndexer(wiki, tmp_path / "data", store=False)


class TestFallbackId:
    def test_no_id_note_indexed_under_stem(self, wiki, tmp_path):
        (wiki / "foam-note.md").write_text(
            "---\ntitle: Foam 노트\n---\n임베딩 없이 만든 노트 본문\n", encoding="utf-8"
        )
        ix = _ix(wiki, tmp_path)
        ix.build(verbose=False)

        assert ix.notes["foam-note"]["id_source"] == "filename"
        assert ix.notes["foam-note"]["id"] == "foam-note"
        assert ix.notes["foam-note"]["title"] == "Foam 노트"
        assert [r["id"] for r in ix.search_hybrid("노트 본문")] == ["foam-note"]

    def test_frontmatter_id_wins_and_marks_source(self, wiki, tmp_path):
        (wiki / "note.md").write_text(
            "---\nid: real-id\ntitle: 제목\n---\n본문\n", encoding="utf-8"
        )
        ix = _ix(wiki, tmp_path)
        ix.build(verbose=False)

        assert ix.notes["real-id"]["id_source"] == "frontmatter"
        assert "note" not in ix.notes  # stem 이 id 를 대신하지 않는다

    def test_link_to_fallback_note_not_broken(self, wiki, tmp_path):
        (wiki / "hub.md").write_text(
            "---\nid: hub\n---\n- [[foam-note]] 참조\n", encoding="utf-8"
        )
        (wiki / "foam-note.md").write_text("frontmatter 없이 본문만\n", encoding="utf-8")
        ix = _ix(wiki, tmp_path)
        ix.build(verbose=False)

        assert WikiGraph(ix).find_broken_links() == []
        assert ix.in_links.get("foam-note") == {"hub"}

    def test_collision_frontmatter_id_wins_regardless_of_scan_order(
        self, wiki, tmp_path, capsys
    ):
        # frontmatter 노트를 정렬상 뒤에 오는 하위 폴더(zz/)에 둔다 — rglib 이
        # dup.md 를 먼저 스캔하든 zz/holder.md 를 먼저 스캔하든 결과가 같아야 한다.
        (wiki / "dup.md").write_text("---\ntitle: dup 파일\n---\n본문\n", encoding="utf-8")
        sub = wiki / "zz"
        sub.mkdir()
        (sub / "holder.md").write_text(
            "---\nid: dup\n---\nfrontmatter 노트\n", encoding="utf-8"
        )
        ix = _ix(wiki, tmp_path)
        ix.build(verbose=True)

        assert ix.notes["dup"]["id_source"] == "frontmatter"
        assert ix.notes["dup"]["path"] == str(Path("zz") / "holder.md")
        assert [n["path"] for n in ix.notes.values()] == [str(Path("zz") / "holder.md")]
        err = capsys.readouterr().err
        assert (
            "dup.md: frontmatter id 없음, 파일 이름 'dup' 이 이미 다른 노트 id — 건너뜀" in err
        )

    def test_two_fallbacks_same_stem_first_sorted_wins(self, wiki, tmp_path, capsys):
        (wiki / "aa").mkdir()
        (wiki / "zz").mkdir()
        (wiki / "aa" / "same.md").write_text("aa 쪽 본문\n", encoding="utf-8")
        (wiki / "zz" / "same.md").write_text("zz 쪽 본문\n", encoding="utf-8")
        ix = _ix(wiki, tmp_path)
        ix.build(verbose=True)

        assert len(ix.notes) == 1
        assert ix.notes["same"]["path"] == str(Path("aa") / "same.md")
        err = capsys.readouterr().err
        assert (
            f"{Path('zz/same.md')}: frontmatter id 없음, 파일 이름 'same' 이 "
            f"이미 다른 노트 id — 건너뜀" in err
        )

    def test_empty_and_missing_frontmatter_both_use_stem(self, wiki, tmp_path):
        (wiki / "empty-fm.md").write_text("---\n---\n빈 frontmatter 노트\n", encoding="utf-8")
        (wiki / "no-fm.md").write_text("frontmatter 없는 노트\n", encoding="utf-8")
        ix = _ix(wiki, tmp_path)
        ix.build(verbose=False)

        assert ix.notes["empty-fm"]["id_source"] == "filename"
        assert ix.notes["no-fm"]["id_source"] == "filename"

    def test_hidden_dirs_ignored_even_without_id(self, wiki, tmp_path):
        (wiki / ".foam" / "templates").mkdir(parents=True)
        (wiki / ".foam" / "templates" / "new-note.md").write_text("템플릿 본문\n", encoding="utf-8")
        (wiki / ".vscode").mkdir()
        (wiki / ".vscode" / "settings-note.md").write_text("설정 메모\n", encoding="utf-8")
        ix = _ix(wiki, tmp_path)
        ix.build(verbose=False)

        assert ix.notes == {}
        assert ix.all_ids == set()


class TestUpdateNotePromotesFallback:
    def test_update_note_writes_stem_id_into_frontmatter(self, wiki, tmp_path):
        (wiki / "foam-note.md").write_text(
            "---\ntitle: Foam 노트\n---\n처음 본문\n", encoding="utf-8"
        )
        ix = _ix(wiki, tmp_path)
        ix.build(verbose=False)
        assert ix.notes["foam-note"]["id_source"] == "filename"

        result = writer.update_note(ix, "foam-note", body="수정된 본문")
        assert result["status"] == "ok"

        # update_note 는 frontmatter 재조립 시 id=<stem> 을 써넣는다 — 노트 "승격"
        post = frontmatter.load(wiki / "foam-note.md")
        assert post["id"] == "foam-note"
        assert post.content.strip() == "수정된 본문"

        ix.build(verbose=False)
        assert ix.notes["foam-note"]["id_source"] == "frontmatter"
