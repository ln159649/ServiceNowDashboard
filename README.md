# ServiceNow Incident Analysis: Where Do Resolution Delays Come From?

**In short:** About half of IT incidents are passed between teams at least once, and those incidents account for nearly three quarters of elapsed resolution time. Median resolution time rises from under an hour with no reassignments to about two weeks with six or more. This is an association, not proof of cause, so the suggested next step is a small pilot of better first-time routing.

**Audience:** An IT service desk manager deciding where to focus process improvements.
**Tools:** PostgreSQL (CTEs, window functions, percentiles), Power BI
**Dashboard:** two pages built in Power BI Desktop (file: `ServiceNow.pbix`)

## Business question

When IT incidents are resolved, where does the time go, and what is the most promising place to cut delays?

## Data

[Incident management process enriched event log](https://archive.ics.uci.edu/dataset/498/incident+management+process+enriched+event+log), UCI Machine Learning Repository (CC BY 4.0). It is an anonymized audit log from a ServiceNow instance at an IT company: 141,712 events across 24,918 incidents and 36 attributes, with incidents opened between February 2016 and February 2017.

The file has one row per update to an incident, so I collapsed it to one row per incident using the update counter (`sys_mod_count`).

## Definitions

- **Resolution time:** calendar hours from an incident being opened to being resolved. It is elapsed time, not staff effort.
- **Reassignment:** a change of assignment group during an incident's life.
- **SLA met:** the flag recorded in the data (`made_sla`). SLA targets depend on elapsed time, so SLA results overlap with resolution-time results.
- **Resolved incidents:** the 23,362 incidents with a resolved timestamp. Timing metrics use only these.

## Approach

1. Loaded the raw CSV as text, then cleaned it: `?` became NULL, day/month/year timestamps were parsed, and boolean flags were converted.
2. Built an incident-level view holding each incident's final state and its resolution time in hours.
3. Analyzed resolution time by priority, the distribution of resolution times, reassignments, SLA by assignment group, and time spent in each state (using the `LEAD` window function).
4. Built a two-page Power BI dashboard (Overview and Drivers) from the results, checking each measure against the SQL output.

All SQL is in [`incident_analysis.sql`](incident_analysis.sql).

## Key findings

**1. Most incidents resolve quickly, but a long tail is slow.** Of 23,362 resolved incidents, 51.7% were resolved within 24 hours (32.1% in under an hour), 22.9% took more than 7 days, and 4.9% took more than 30 days. Averages are far above medians, so I report medians and percentiles.

**2. Reassignments go with much slower resolution.** 48.6% of resolved incidents were reassigned at least once, and reassigned incidents account for 72.6% of total elapsed resolution time. Median resolution time across all priorities is 0.7 hours with no reassignment, 50.6 hours (1-2 reassignments), 167.8 hours (3-5), and 336.6 hours (6+), or roughly 40 minutes, 2 days, 1 week and 2 weeks. Moderate-priority incidents alone (94% of volume) show the same pattern at 0.6, 51.7, 168.1 and 336.8 hours, so the result is not just a priority mix effect. Of the 538 incidents reassigned six or more times, about 80% took longer than a week (62.6% took 7-30 days and 17.5% took over 30 days).

**3. SLA attainment falls as reassignments rise.** Across resolved incidents, SLA was met 77.1%, 52.5%, 28.8%, and 8.6% of the time for 0, 1-2, 3-5, and 6+ reassignments. Overall, 63.4% of all incidents met their SLA. Among groups with at least 100 incidents, Group 12 was lowest at 13.0% (123 incidents), followed by Groups 37 and 10 at about 25%. Groups differ in workload mix, so this shows where to investigate, not which group performs worst.

**4. Much of the time is spent waiting.** Excluding the post-resolution wait before auto-close, the largest shares of time are Active (18.0% of all time), Awaiting User Info (15.7%), and New (13.8%, before work starts). Awaiting Vendor is slow per event (about 16 days) but rare (3.4% of all time). Closed (0.3%) and Awaiting Evidence (0.2%) are small.

**5. Higher-priority incidents were slower at the median.** Critical incidents had a median of 80.2 hours versus 5.0 for Low. Among incidents with no reassignments, Critical still took a median of 95.2 hours versus 0.6 for Moderate, so handoffs alone do not explain the gap. Critical (270) and High (408) are small groups, so treat these figures as indicative.

## Recommendation

The reassignment pattern is consistent: it grows at every level and holds within Moderate priority. But there are several possible explanations, including that harder incidents get reassigned more. When the cause is unclear, a low-risk test is better than a large change.

1. **Pilot better first-time routing** in one assignment group and compare reassignment rates and resolution times with a similar group.
2. **If the pilot works, scale it.** If not, the delay is more likely in the incident type than in the routing.
3. **Secondary levers:** capture the information needed from users earlier, and shorten the time incidents spend in New before work starts.

## Limitations

- **Association, not causation.** Harder incidents may be reassigned more often.
- **SLA overlaps with timing.** SLA targets are tied to elapsed time, so the SLA result largely restates the resolution-time result.
- **Unresolved incidents.** 1,556 incidents (6.2%) were never resolved and are excluded from timing metrics; 1,546 of them had no reassignments.
- **No reliable monthly trend.** About 99% of incidents were opened between February and May 2016, which looks like an extraction effect.
- **Elapsed time is not effort.** Hours are calendar time between events, not staff time.
- **Small samples.** There are too few Critical and High incidents with 3+ reassignments to draw conclusions.
- **Anonymized groups.** Assignment groups differ in workload mix, so the SLA ranking shows where to investigate, not who performs worst.
- **Data quality.** One state value, `-100` (5 events), is invalid and excluded.
