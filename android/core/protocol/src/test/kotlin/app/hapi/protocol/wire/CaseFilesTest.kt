package app.hapi.protocol.wire
import kotlin.test.*
import org.junit.Test
class CaseFilesTest {
 @Test fun decodeActualHubContract() {
  val index=HapiJson.decodeFromString<CaseFilesResponse>("""{"files":[{"id":"report","category":"deliverables","fileName":"中文报告.pdf","mimeType":"application/pdf","size":1234,"createdAt":1795491000000,"downloadPath":"/api/sessions/s/generated-images/report"},{"id":"original","category":"uploads","fileName":"单据.zip","mimeType":"application/zip","size":777,"createdAt":1795491000001}]}""")
  assertEquals(2,index.files.size);assertTrue(index.files[0].isPdf);assertFalse(index.files[0].isUpload);assertTrue(index.files[1].isUpload);assertTrue(index.files[1].isZip);assertEquals("uploads:original",index.files[1].key)
 }
}
