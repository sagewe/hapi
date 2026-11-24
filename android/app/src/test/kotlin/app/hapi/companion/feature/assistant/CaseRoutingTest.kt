package app.hapi.companion.feature.assistant
import org.junit.Test
import org.junit.Assert.*
import app.hapi.protocol.wire.CaseFile
class CaseRoutingTest {
 @Test fun incomingShareGuard() { assertEquals(IncomingCaseRoute.Draft,incomingCaseRoute(null));assertEquals(IncomingCaseRoute.AskCurrentCase,incomingCaseRoute("old-case")) }
 @Test fun mainReportPreferredToExtract() { fun pdf(id: String,name: String)=CaseFile(id,"deliverables",name,"application/pdf",1,1.0)
  val extract=pdf("extract","官方摘录.pdf");val report=pdf("report","中文尽调报告.pdf");assertEquals(report,primaryReport(listOf(extract,report)))
 }
}
