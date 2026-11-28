---
name: start-task
description: 기획 에이전트가 새 작업(이슈)을 시작할 때 쓰는 착수 절차. 겹치는 작업 확인, 전용 worktree 생성, 브랜치 클레임, 플랜 작성, PR 열기, PR 감시까지. 새 이슈·기능·수정 작업에 착수한다는 말이 나오면 쓴다.
---

# 작업 착수

규칙의 원본은 `AGENTS.md`다(워크플로우, 병렬 세션 규칙, 이슈·라벨·마일스톤, 승인과 머지). 이 스킬은 순서와 명령만 담는다.

입력: 이슈 번호 `NNN`, 등급(`small`/`large`), 주제(영문 짧은 이름).

## 1. 사전 확인

1. `gh issue view NNN`으로 라벨을 본다. `needs-decision`이 있으면 **여기서 멈추고** 사용자에게 알린다(PR을 열지 않는다).
2. `git worktree list`와 `git branch -r`로 같은 일을 하는 세션이 없는지 본다. 겹치면 멈추고 사용자에게 보고한다. 남의 worktree·브랜치는 건드리지 않는다.

## 2. worktree와 클레임

메인 체크아웃은 읽기 전용이다. 거기서 `cd`한 채로 commit·push하면 훅이 막으므로 worktree 안에서 한다.

```
git worktree add ../outpost-<주제> -b <feat|fix|chore>/NNN-<이름> origin/main
cd ../outpost-<주제> && npm ci
git push -u origin <브랜치>
```

브랜치를 먼저 push해 자리를 잡은 뒤 작업을 시작한다.

## 3. 등급별 진행

### large

0. 비주얼 방향이나 새 상호작용처럼 감각으로 정해야 하면, 플랜 전에 비교용 draft PR(쿼리 스위치 등, 머지 안 함)로 사용자에게 먼저 보여 방향을 정한다. 결정 뒤 비교 PR은 닫는다(AGENTS.md 워크플로우).
1. `docs/templates/plan.md`로 `docs/plans/NNN-*.md`를 쓴다. 플랜에는 **목표 상태만** 쓴다(세션 경위·파일 출처 메모 금지).
2. draft PR을 연다: 라벨 `size:large` + `stage:plan-review`, 마일스톤, 본문 `관련 이슈`와 플랜 링크.
3. neon은 push 직후 훅이 자동으로 돌린다. 직접 부르지 않는다. 결과는 PR 본문 `리뷰 기록` 표에 적는다.
4. Codex는 플랜이 정리된 뒤 PR 코멘트로 `@codex review`를 요청한다(리뷰는 최대 3턴).

### small

1. 플랜·tasks·QA 리포트는 생략한다. 변경 이유와 검증 결과를 PR 본문에 쓴다.
2. 구현·검증 뒤 **ready로** 연다: 라벨 `size:small` + `stage:code-review`, 마일스톤, 본문 `관련 이슈`.
3. 연 직후 `gh pr merge <번호> --auto --squash`로 auto-merge를 예약한다.
4. `src/scene/`·`src/ui/`·`src/index.css`를 바꿨으면 Preview 배포 뒤 `scripts/snapshot-critique.sh <번호>`를 실행한다(배포 봇 코멘트의 배포 SHA가 head와 같을 때만 촬영하고, 다르면 최대 10분 기다린다). 지적은 반영하거나 `art-ux` 이슈로 올린다.
5. 최종 SHA에 `@codex review`를 요청한다.

## 4. PR 열기

- 본문은 `.github/pull_request_template.md` 형식으로 파일에 써서 `gh pr create --body-file <파일>`로 넘긴다(`--body` 인라인 금지).
- 커밋 메시지·본문에 예시 명령이나 `;`·`&&` 같은 글자가 들어가면 훅이 오탐할 수 있다. 파일로 넘긴다(`git commit -F`).
- `gh pr merge` 등에는 PR 번호를 **리터럴로** 쓴다(변수·치환 금지).
- 모든 PR은 에이전트 계정으로 연다. 라벨은 `size:*` 1개와 `stage:*` 1개, 마일스톤 필수.

## 5. 감시

PR을 연 직후 Monitor 도구로 `scripts/watch-pr.sh N 60`을 띄운다(N은 PR 번호). 새 코멘트·리뷰가 알림으로 온다. AI 리뷰는 바로 반영하고 사용자 코멘트는 정리만 한다(`CLAUDE.md`의 "PR 감시와 리뷰 반영").

머지 뒤 worktree·브랜치 정리는 `retro` 스킬 4단계에서 한다.
