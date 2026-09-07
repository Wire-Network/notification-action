# CI/CD Notification Action

A reusable GitHub Action for sending workflow status notifications to Mattermost or Slack. Supports all GitHub Actions job statuses: success ✅, failure ❌, cancelled ⚫, and skipped ⏭️.

## Status Indicators

| Status | Emoji | Color | Description |
|--------|-------|-------|-------------|
| Success | ✅ | Green (#00FF00) | All jobs completed successfully |
| Failure | ❌ | Red (#FF0000) | One or more jobs failed |
| Cancelled | ⚫ | Gray (#808080) | Workflow was cancelled |
| Skipped | ⏭️ | Orange (#FFA500) | Jobs were skipped |

`success` is reported only when every job result is exactly `success`. Otherwise the
worst status wins, in the order `failure` > `cancelled` > `skipped`, and any value outside
that set is reported as ❓ UNKNOWN rather than folded into green.

The action **fails closed**: `job-results` that parses to nothing, or an entry without a
non-empty status, exits the step non-zero instead of sending a notification. A silent
fallthrough to green is what let comma-separated `job-results` report success over failing
builds.

## Usage

   ```yaml
     uses: Wire-Network/notification-action@v1
     with:
       webhook-url: ${{ secrets.WEBHOOK_URL }}
       # ... other inputs
   ```

Ensure you have setup WEBHOOK_URL in your repository secrets.

### Basic Example (Single Job)

```yaml
name: Build and Test
on: [push, pull_request]

jobs:
  build-and-test:
    name: Build and Test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: npm run build
      - name: Test
        run: npm test

  notification:
    name: Send Notification
    needs: [build-and-test]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Send Notification
        uses: Wire-Network/notification-action@v1
        with:
          webhook-url: ${{ secrets.WEBHOOK_URL }}
          notification-type: 1
          channel: cicd-notifications
          workflow-name: "Build & Test Workflow"
          job-results: "build-and-test:${{ needs.build-and-test.result }}"
          github-context: ${{ toJSON(github) }}
```

### Advanced Example (Multiple Jobs)

```yaml
name: Build and Test
on: [push, pull_request]

jobs:
  tests:
    name: Run Tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ...

  np-tests:
    name: Run NP Tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ...

  lr-tests:
    name: Run LR Tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ...

  all-passing:
    name: All Required Tests Passed
    needs: [tests, np-tests, lr-tests]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Send Notification
        uses: Wire-Network/notification-action@v1
        with:
          webhook-url: ${{ secrets.WEBHOOK_URL }}
          notification-type: 1
          channel: cicd-notifications
          workflow-name: "Build & Test Workflow"
          job-results: |
            tests:${{ needs.tests.result }}
            np-tests:${{ needs.np-tests.result }}
            lr-tests:${{ needs.lr-tests.result }}
          github-context: ${{ toJSON(github) }}

      - name: Fail if any tests failed
        if: |
          needs.tests.result != 'success' || 
          needs.np-tests.result != 'success' || 
          needs.lr-tests.result != 'success'
        run: exit 1
```

### Using with Slack

Simply change the `notification-type` to `2` and provide the Slack channel ID:

```yaml
- name: Send Slack Notification
  uses: Wire-Network/notification-action@v1
  with:
    webhook-url: ${{ secrets.SLACK_WEBHOOK_URL }}
    notification-type: 2
    channel: C01234567  # Slack channel ID
    job-results: "build-and-test:${{ needs.build-and-test.result }}"
    github-context: ${{ toJSON(github) }}
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `webhook-url` | Yes | - | Webhook URL for Slack or Mattermost |
| `notification-type` | Yes | `1` | Notification service: `1` for Mattermost, `2` for Slack |
| `channel` | No | `cicd-notifications` | Channel name (Mattermost) or channel ID (Slack) |
| `workflow-name` | Yes | - | Name of the workflow (e.g., `Build & Test Workflow`) |
| `job-results` | Yes | - | Job results as `job:status` pairs (comma-, space- or newline-separated) or a JSON object |
| `github-context` | Yes | - | JSON string of GitHub context |

### Job Results Format

You can pass job results in two formats. Entries may be separated by any mix of
commas, spaces and newlines.

**Simple format (recommended):**

```yaml
job-results: |
  tests:${{ needs.tests.result }}
  build:${{ needs.build.result }}
  deploy:${{ needs.deploy.result }}
```

Or inline for single job:

```yaml
job-results: "build-and-test:${{ needs.build-and-test.result }}"
```

Or comma-separated on one line:

```yaml
job-results: "tests:${{ needs.tests.result }},build:${{ needs.build.result }}"
```

**JSON format (also supported):**

```yaml
job-results: '{"tests":"success","build":"failure","deploy":"skipped"}'
```

## Development

`scripts/notify.sh` holds the implementation; `action.yaml` only passes the inputs
through the environment. Run the suite with:

```bash
tests/run-tests.sh
```

It exercises every separator form, the status precedence, the fail-closed paths, the
rendered payload and the webhook call itself against a local sink. `NOTIFY_DRY_RUN=1`
prints the payload to stdout and skips the webhook.

## Tips

1. **Always use `if: always()`** on the notification job to ensure it runs even if other jobs fail
2. **Keep webhook URLs in secrets**
3. **Use meaningful job names** - they'll be formatted and displayed in notifications
4. **Test with workflow_dispatch** to manually trigger and verify notifications

## Versioning

You can reference the aciton several ways:

- **Specific tag**: `wire-network/notification-action@v1` (recommended)
- **Specific commit**: `wire-network/notification-action@abc1234` (for testing)
- **Branch**: `wire-network/notification-action@master`

### Creating New Versions

When you make changes to the action:

```bash
# Tag a new version
git tag -a v1.1.0 -m "Your commit message"
git push origin v1.1.0

# Update the major version tag to point to latest
git tag -fa v1 -m "Update v1 to v1.1.0"
git push origin v1 --force
```
