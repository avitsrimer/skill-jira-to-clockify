# 1 Jira day = 6 hours = 21600 seconds
def to_days:
  if . == null or . == 0 then "0"
  else ((. / 21600 * 100 | round) / 100 | tostring) + "d"
  end;

{
  ticket_id: .key,
  ticket_name: .fields.summary,
  parent_id: (.fields.parent.key // ""),
  parent_name: (.fields.parent.fields.summary // ""),
  status: .fields.status.name,
  resolution_date: ((.fields.resolutiondate // "")[0:10]),
  worklogs: [
    .fields.worklog.worklogs[]
    | select(.author.displayName == $author)
    | select(.started[0:10] >= $start and .started[0:10] <= $end)
    | {
        date: .started[0:10],
        time_days: (.timeSpentSeconds | to_days),
        time_seconds: (.timeSpentSeconds // 0)
      }
  ]
}
| if (.worklogs | length) > 0 then
    .worklogs[] as $wl |
    [.ticket_id, .ticket_name, .parent_id, .parent_name, .status, $wl.date, $wl.time_days, ($wl.time_seconds | tostring), .resolution_date]
    | @csv
  else
    [.ticket_id, .ticket_name, .parent_id, .parent_name, .status, "", "", "0", .resolution_date]
    | @csv
  end
