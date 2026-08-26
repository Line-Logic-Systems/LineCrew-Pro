from pathlib import Path

path = Path('timekeeping-payroll.js')
text = path.read_text()
old = """    const crewDayTotals=new Map();
    byPersonDay.forEach((segs,key)=>{
      const [employeeId,date]=key.split('|');
      const employee=employeeMap.get(employeeId)||{};
      const crew=String(segs.find(r=>r.crew_name)?.crew_name||employee.default_crew_name||'').trim();
      if(!crew)return;
      const total=segs.reduce((sum,r)=>sum+num(r.regular_hours)+num(r.overtime_hours),0);
      const crewKey=`${crew.toLowerCase()}|${date}`;
      if(!crewDayTotals.has(crewKey))crewDayTotals.set(crewKey,{crew,date,members:[]});
      crewDayTotals.get(crewKey).members.push({employee:employee.full_name||'Employee',total});
    });
    crewDayTotals.forEach(group=>{
      if(group.members.length<2)return;
      const buckets=new Map();
      group.members.forEach(m=>{const k=m.total.toFixed(2);if(!buckets.has(k))buckets.set(k,[]);buckets.get(k).push(m);});
      if(buckets.size<=1)return;
      const majority=[...buckets.entries()].sort((a,b)=>b[1].length-a[1].length)[0];
      const expected=majority[0];
      group.members.forEach(m=>{
        if(m.total.toFixed(2)!==expected)out.push({type:'crew-hours',employee:m.employee,date:group.date,message:`${m.total.toFixed(2)} hours recorded; other members of crew ${group.crew} are at ${Number(expected).toFixed(2)} hours.`});
      });
    });
"""
new = """    // Crew-hour mismatch is a Daily Report-level check, not a roster/default-crew check.
    // Only working employees participate, and at least four employees must agree on the
    // same daily total before an outlier is flagged. This avoids false positives on days
    // when only one or two people worked while still catching the normal 5-person 4-to-1 case.
    const reportDayTotals=new Map();
    byPersonDay.forEach((segs,key)=>{
      const [employeeId,date]=key.split('|');
      const employee=employeeMap.get(employeeId)||{};
      const total=segs.reduce((sum,r)=>sum+num(r.regular_hours)+num(r.overtime_hours),0);
      if(total<=0)return;
      const reportIds=[...new Set(segs.map(r=>r.daily_report_id).filter(Boolean))];
      if(reportIds.length!==1)return;
      const reportId=reportIds[0];
      const reportKey=`${reportId}|${date}`;
      if(!reportDayTotals.has(reportKey))reportDayTotals.set(reportKey,{reportId,date,members:[]});
      reportDayTotals.get(reportKey).members.push({employee:employee.full_name||'Employee',total});
    });
    reportDayTotals.forEach(group=>{
      if(group.members.length<5)return;
      const buckets=new Map();
      group.members.forEach(m=>{const k=m.total.toFixed(2);if(!buckets.has(k))buckets.set(k,[]);buckets.get(k).push(m);});
      if(buckets.size<=1)return;
      const majority=[...buckets.entries()].sort((a,b)=>b[1].length-a[1].length)[0];
      if(majority[1].length<4)return;
      const expected=majority[0];
      group.members.forEach(m=>{
        if(m.total.toFixed(2)!==expected)out.push({type:'crew-hours',employee:m.employee,date:group.date,message:`${m.total.toFixed(2)} hours recorded; the Daily Report majority is ${Number(expected).toFixed(2)} hours (${majority[1].length} crew members).`});
      });
    });
"""
if old not in text:
    raise SystemExit('Target exception block not found; refusing to patch')
path.write_text(text.replace(old, new, 1))
