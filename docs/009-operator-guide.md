# 009 Operator guide

For the person who uses this every day, not the person who installs it. It says what the panel shows, what to do when
something waits for you, and what not to do. Installing and configuring are in [006](006-deployment.md).

## What it is

An agent works on one repository. It reads requests that arrive through GitHub, turns each into a **Ticket**, does the work
in its own session, opens a pull request, and tells you when it needs a decision. You are not driving it; you are answering
it when it asks.

## The four things the overview shows

| Section | What it means | What you do |
| --- | --- | --- |
| **Pending Tickets** | Work that has stopped and needs a person | Answer, retry, split or stop it — see below |
| **System problems** | Something in the installation is wrong: setup, a Source, a failed message | Fix what it names, or tell whoever runs the machine |
| **Last 24 hours** | How many requests arrived and how many became work | Nothing; this is the pulse |
| **Calibration** | Where the agent's judgement disagreed with yours | Read it when you have a minute, and narrow or widen a rule |
| **Recent activity** | What just happened, newest first | Nothing; this is the trail |

## Three situations you will meet

### A Ticket is waiting for an answer

The Ticket reads **Awaiting answer** and shows the question. **Answer in the channel it came from** — the button on the Ticket
opens it. The agent continues by itself once you answer; there is nothing to press in the panel.

### A Ticket failed

The Ticket reads **Failed**, and the banner shows the error plus what you can do:

- **Retry** — the same worker continues from where it stopped. Do this when the failure looks like a hiccup: a timeout, a
  red check that has since been fixed, a file that was locked.
- **Split into smaller Tickets** — replaces this one with two to six smaller ones that keep its authority. Do this when the
  failure is "this asked for too much at once". Each part may wait for an earlier part, so an ordered request stays ordered.
- **Stop** — gives up on this request. Nothing is undone: any pull request it opened stays open for you to close.

Read the error before choosing. Splitting a Ticket whose failure was a typo only makes two Tickets with the same typo.

### You think it judged something wrong

Open **Calibration**. It counts the two disagreements that matter: a request it accepted that a person then closed, and a
request it ignored whose thread went on to have work anyway. Each case opens the thread it came from, which is where you
can see what the rules missed.

The fix is a **rule**, not a retry: rules live under Settings → Policy. A rule says what kind of request the agent may take
on its own; it is not a per-case permission.

## What not to do

- **Do not push to the repository by hand while a Ticket works there.** Two writers on one branch is a conflict the agent
  will spend its retries on.
- **Do not stop a Ticket to "pause" it.** Stop ends the mandate; a stopped Ticket does not resume.
- **Do not change a Source's account fields from the main Session.** Setup fields belong to the panel, and a change there
  restarts the service.
- **Do not treat the agent's "ready" as a merge.** A pull request it calls ready is ready for review; the merge is yours
  unless an auto-merge rule covers those paths.

## When the panel does not answer

The service restarted, or it stopped. Whoever runs the machine can bring it back with `scripts\superagent.ps1 start` on
Windows; a watchdog normally does it within five minutes. Nothing is lost: work in flight resumes from its Ticket.
