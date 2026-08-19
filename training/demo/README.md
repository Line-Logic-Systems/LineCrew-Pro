# LineCrew Pro Training Demo Studio

This directory contains static, isolated training/demo screens for generating screenshots, videos, documentation, and sales/training material.

## Safety model

- Demo pages do **not** load Supabase.
- Demo pages do **not** authenticate users.
- Demo pages do **not** read or write production data.
- All names, jobs, units, hours, photos, and records shown are fictional sample data.
- A visible TRAINING DEMO banner distinguishes these pages from production.
- Do not add production keys, customer information, or real employee information here.

## Purpose

The demo screens mirror the vocabulary and general workflow of the production application closely enough to produce clean training screenshots without exposing a live contractor account to third-party video tools.

Initial walkthrough: `foreman.html` covers Dashboard -> Morning JSA -> JSA completion -> Daily Report -> units -> attachments -> review -> submission.

Future role walkthroughs should be added as separate static pages for General Foreman, Superintendent, Admin, and Owner.