# Daily Mio review

Open Mio Settings → Daily Mio review. Choose an executable or wrapper for your harness and a local Mio source checkout. Enter any arguments, one per line, and a time in HH:MM. The default is 00:00 in the Mac's current time zone. Enable the review and confirm the selected harness, project and time. It is off until this confirmation succeeds.

Mio registers a user LaunchAgent for this schedule. The timer checks the local minute while the user is signed in, even when the Mio window and process are closed. It claims one run per scheduled local date. After sleep or a missed start, it handles the most recent eligible occurrence. The review covers the interval between consecutive scheduled times. At midnight that is the preceding local calendar day. Enabling starts with the next scheduled time.

## Harness contract

Use a harness configured to run without interactive input or approvals. Mio starts the configured executable directly in the project folder and sends the task as UTF-8 text on stdin. For a harness that accepts files, the argument placeholders `{prompt_file}`, `{telemetry_file}`, and `{analysis_file}` are replaced with absolute paths. Arguments are passed individually to the executable.

Each daily run invokes the same harness twice:

1. `MIO_REVIEW_PHASE=analysis` receives an aggregate snapshot of that day's Mio operations. Write the analysis to stdout and exit successfully.
2. `MIO_REVIEW_PHASE=work` receives the analysis and telemetry. Make the justified local changes in the chosen checkout and run the relevant tests. Write the work summary to stdout. A failed or empty analysis prevents this phase.

The files are also available through `MIO_REVIEW_PROMPT_PATH`, `MIO_REVIEW_TELEMETRY_PATH`, and `MIO_REVIEW_ANALYSIS_PATH`. Telemetry contains counts, outcomes, durations and usage indicators. The app does not send note bodies, query text, profile tokens or chat transcripts. The executable runs with the signed-in user's permissions and can use its configured providers. Keep its access and batch flags appropriate for the selected project. The scheduled job authorizes local code changes and tests.

In Settings, Open review results shows the telemetry, analysis, work output, stderr and status. Disabling stops future runs and prevents the work phase from starting if the analysis is still running. A phase already started can finish.
