---
description: Vault structure guide for DailyWerk agent
version: 1
---

# Vault Structure Guide

This document tells DailyWerk's AI agent how to organize files in this vault.
Edit it to match your preferred structure.

## Folder Structure

- `00 - Inbox/` for quick captures and unsorted notes
- `01 - Daily Notes/YYYY-MM/` for daily notes and month overviews
- `01 - Note Summaries/Weekly Notes/` and `Monthly Notes/` for rollups
- `02 - Areas/` for ongoing areas like work, health, meetings, and research
- `03 - Resources/` for reference material and saved knowledge
- `04 - Archive/` for completed or inactive material

## Placement Rules

1. Daily notes go in `01 - Daily Notes/YYYY-MM/YYYY-MM-DD.md`
2. Meeting notes go in `02 - Areas/Meetings/YYYY-MM-DD - {title}.md`
3. Health logs go in `02 - Areas/Health/`
4. Research goes in `03 - Resources/{topic-slug}/`
5. Quick captures go in `00 - Inbox/`
6. Attachments stay next to the note that references them

## Naming Conventions

- Prefer lowercase-kebab-case file names
- Use ISO dates for date-prefixed files
- Keep numbered prefixes on top-level folders for sort order

## Frontmatter Schemas

- Add `title` when the file name is not user-friendly
- Add `date` for time-based notes
- Add `tags` as an array when tags matter for retrieval

## Linking

- Prefer wikilinks for note-to-note references
- Escape alias pipes inside markdown tables as `\|`
- Keep attachments in the same folder as the note that references them

## Search Relevance

- Put canonical facts in markdown prose, not screenshots
- Use clear headings for major sections
- Keep one topic per note when possible

## Agent Behaviors

- Read this guide before creating or moving files
- Never write to `_dailywerk/` except when updating this guide
- Preserve user-authored structure unless the guide says otherwise
