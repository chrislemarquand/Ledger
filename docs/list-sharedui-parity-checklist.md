# SharedUI List Migration Parity Checklist

Purpose: move Ledger list view implementation into SharedUI with zero UI/UX/behavior changes before any native-selection cleanup.

## Baseline

- [ ] Current branch commit recorded.
- [ ] App built and launched from Xcode/DerivedData successfully.
- [ ] `reset_ledger_layout.sh --yes` run before baseline pass.

## List Interaction Parity

- [ ] Single-click selects one row.
- [ ] `cmd`-click toggles row selection.
- [ ] `shift`-click extends selection range.
- [ ] `cmd`+`shift`-click unions range into existing selection.
- [ ] Background click clears selection.
- [ ] Double-click opens selected file in default app.
- [ ] Return/Enter action still focuses inspector from browser list.
- [ ] Arrow-key navigation still works as before.

## Context Menu Parity

- [ ] Right-click on selected row targets current ordered selection.
- [ ] Right-click on unselected row first selects that row, then menu targets it.
- [ ] Menu items/states match current behavior (enabled/disabled, titles, symbols).

## Column + Layout Parity

- [ ] Default visible columns unchanged (`Name`, `Date Created`, `Size`, `Kind`).
- [ ] Header right-click column toggle menu content/order unchanged.
- [ ] Column visibility persistence unchanged.
- [ ] Column width/order persistence unchanged.
- [ ] Sort indicator + sort descriptor behavior unchanged.
- [ ] Sidebar/inspector toggles keep default list fitting behavior unchanged.
- [ ] Overflow behavior (extra columns) unchanged.

## Selection/Model/QuickLook Parity

- [ ] List selection syncs to model selection unchanged.
- [ ] Programmatic selection sync back into list unchanged.
- [ ] QuickLook source frame updates still track selected row icon.
- [ ] No new selection loops or re-entrant update warnings.

## Persistence + Reset Parity

- [ ] Existing defaults keys for list state still used.
- [ ] `reset_ledger_layout.sh` still restores default list layout/visibility.
- [ ] Relaunch restores prior list state exactly as before migration.

## Regression Guardrails

- [ ] `LedgerTests/AppModelTests` selection-related tests pass.
- [ ] No behavior changes outside list view (gallery/sidebar/inspector/toolbar).
- [ ] Manual smoke pass completed after migration wiring.

