package app.hapi.protocol.wire
import kotlin.test.*
import org.junit.Test
class CaseFilesTest {
 @Test fun decodeActualHubContract() {
  val index=HapiJson.decodeFromString<CaseFilesResponse>("""{"files":[{"id":"report","category":"deliverables","filename":"中文报告.pdf","mime_type":"application/pdf","size":1234,"created_at":1795491000000,"download_path":"/v1/sessions/s/blobs/report"},{"id":"original","category":"uploads","filename":"单据.zip","mime_type":"application/zip","size":777,"created_at":1795491000001}]}""")
  assertEquals(2,index.files.size);assertTrue(index.files[0].isPdf);assertFalse(index.files[0].isUpload);assertTrue(index.files[1].isUpload);assertTrue(index.files[1].isZip);assertEquals("uploads:original",index.files[1].key)
  assertEquals("/v1/sessions/s/blobs/report", index.files[0].downloadPath)
 }
}
