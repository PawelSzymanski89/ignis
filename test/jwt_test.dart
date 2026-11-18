// Test Jwt.rs256 — podpis porównany z wektorem z `openssl dgst -sha256 -sign`
// (klucz RSA wygenerowany WYŁĄCZNIE do tego testu), PKCS#8 i PKCS#1, bez bazy.
import '../lib/engine/jwt.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

const claims = {'iss': 'test@example.invalid', 'iat': 1700000000};
const vector = 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJ0ZXN0QGV4YW1wbGUuaW52YWxpZCIsImlhdCI6MTcwMDAwMDAwMH0.GdMR88oud8UpPWl4pv3OJuWUYG-a9X01bSmu7BvqOImLqWjtwnnjCFdU5x2V5HjChuhYIdkyhlJDECMsFkwdRz697vQc-aj6dp0EBYcEkctPba2hbpVnyyO0faMaN0_kGpxy6eE14DUEk-s6ITtKvK01M6OWE3LxqMdIl2LgrTFAkqeNYsDWDwr9Pn7ezEZNoDIPsUWgKjFqwo1ow5KT9kJ-zFkhbPiDc99Y0cSKuSWmciMRqyXFquxUoiXnU2GaXKIwFAvILvxEAGTxvydWNTKHvCevHO_Z7CgshHR-vviq2PXCRu57l-ZzamYiZPvM8bdxD3FT-FdIsrL1aeS3rw';

const pkcs8 = '''
-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCg4zvWgXSJxv/E
9EODQKSjphJOgkY3YoGTr7ziJwTPUsP2sjJZkC2lGTrJ60pp6dUCCe5dEUN20GF6
cELrXyMbf4StTVELtpVKZ6jwdYOR5nyqDV51hylco1pI/veHJ5lkGATieq3baOQv
NzUSmOXdkPy9+bBhce0bm91oVnKtNqVJSCNfGnVF7+dEYzkc/BEhHqDH4cE6k85F
ltWP2n2NJWEJendFuV6yqkeCitMy6WlY7KHbsRkvpTWrkiNuJkLPzMlQ39f2QfzH
o3FK9p4JiZbklwSSV5D7aJUEuNG/JmmPe6yeqC7RRIMgrVODXR6Xl/h4i5KZ3tBj
QGj5YKA7AgMBAAECggEAS/AVLUD7FZDU5kx4lTnsu8VF/MJmi/u1t1SKbaAHGCgz
kHw5Yaa4tKV85xNkkysoPAcd99WPJ0Rhzh2wqFHGS1Nb90R4DXRHcNAOoDiHOlU0
4DrhK835Ct2bXrrhcGyTbPgdThyjdN1EXrjLFxUN4g9uC+kPhF72kEJ4NaggBnr1
ZEUS/SohFalEmaaBXLDIwYBte3BCBGr1yKMDbm//3noBuAFf+rNPnQ44OG/snx47
PNQcG3jatKLkPcYh/+QTY64oGC6psYbH08IHwi0R/3QNqYwbEGY7xreFizp7kAxn
fpTu8+o2kteedhQPAaLLp4gBq5p1DprIMxLt54C6cQKBgQDaAxNix85p0CiLO/Dh
v8PqWwVbWTyr/erECoWO/CvFK9sonuHcIrIsCMgz6R9wj0GUBe0yGENLn8vIYOGZ
ma56XiRJK0S685mDsW2p/PKvhUke/le8QH7utFsMaZhVfami1KGbU8URzcSKErDI
SXvEf1zdEiEbZwOWVpcejtggcwKBgQC86/6NC+EgLS/9fTxqQarglUcBFyuSWOGp
kAvv6ErRlatg4J5h+4QtwMA9//USYxRelJLU8LtWwa6iC6HNAXJzcZZlCDY0pzix
8CZwXTpcd3CzG953IfFLdpZkD7n/ar5IwwIkwCOz/cvRx4uq3hoD1OrHaz97rwex
76LvWBB3GQKBgGXBe8HmWpye0N2z+4mS1SHEnCp3606ntHUOKCqF3vQntSIvjmIO
O7U74B4CmG8UHlq1rXFtS7O3gQkk1we3aG2rFSqlrG3KF4QVQ4dNDgUIpAl4U4EF
ZXmK6thPTQ/SGGRs9IUoQ1o8/ZgogyToz4D2pWR1+sfsfAsmnWBg8dWrAoGAO3X/
mT8a7TiruRn4sOzYLnVtcq9rPFWTOP4oc6rmGY8E8Knhz68NDCV1nE36QX5Dw/z5
NeJK5GRzZXdJxq9k6Wbf0g7CmNHk60RNpOIC42WIaCcmXtKlEn5RmU7F2Nks6NPP
0edTlWwVAYLPt8jN4VTbTEa6JWCSiHOHEdPi4skCgYBfVHuttIQD3EXJnH097r+W
xi4GJ/1IaKSAO5LKlTN1gNSy5hQUjiZfFyCvCmno+F6wBlX8yHHs2pzHP3x99ks4
GsCyvnG3BVRCKnbzglut08srAdTyXWEf517JeE3t43VfCUwZPVDYXAntg6ILt2CP
RGh+0BxSsh3UtsH3rAo7Og==
-----END PRIVATE KEY-----
''';

const pkcs1 = '''
-----BEGIN RSA PRIVATE KEY-----
MIIEogIBAAKCAQEAoOM71oF0icb/xPRDg0Cko6YSToJGN2KBk6+84icEz1LD9rIy
WZAtpRk6yetKaenVAgnuXRFDdtBhenBC618jG3+ErU1RC7aVSmeo8HWDkeZ8qg1e
dYcpXKNaSP73hyeZZBgE4nqt22jkLzc1Epjl3ZD8vfmwYXHtG5vdaFZyrTalSUgj
Xxp1Re/nRGM5HPwRIR6gx+HBOpPORZbVj9p9jSVhCXp3RblesqpHgorTMulpWOyh
27EZL6U1q5IjbiZCz8zJUN/X9kH8x6NxSvaeCYmW5JcEkleQ+2iVBLjRvyZpj3us
nqgu0USDIK1Tg10el5f4eIuSmd7QY0Bo+WCgOwIDAQABAoIBAEvwFS1A+xWQ1OZM
eJU57LvFRfzCZov7tbdUim2gBxgoM5B8OWGmuLSlfOcTZJMrKDwHHffVjydEYc4d
sKhRxktTW/dEeA10R3DQDqA4hzpVNOA64SvN+Qrdm1664XBsk2z4HU4co3TdRF64
yxcVDeIPbgvpD4Re9pBCeDWoIAZ69WRFEv0qIRWpRJmmgVywyMGAbXtwQgRq9cij
A25v/956AbgBX/qzT50OODhv7J8eOzzUHBt42rSi5D3GIf/kE2OuKBguqbGGx9PC
B8ItEf90DamMGxBmO8a3hYs6e5AMZ36U7vPqNpLXnnYUDwGiy6eIAauadQ6ayDMS
7eeAunECgYEA2gMTYsfOadAoizvw4b/D6lsFW1k8q/3qxAqFjvwrxSvbKJ7h3CKy
LAjIM+kfcI9BlAXtMhhDS5/LyGDhmZmuel4kSStEuvOZg7Ftqfzyr4VJHv5XvEB+
7rRbDGmYVX2potShm1PFEc3EihKwyEl7xH9c3RIhG2cDllaXHo7YIHMCgYEAvOv+
jQvhIC0v/X08akGq4JVHARcrkljhqZAL7+hK0ZWrYOCeYfuELcDAPf/1EmMUXpSS
1PC7VsGuoguhzQFyc3GWZQg2NKc4sfAmcF06XHdwsxvedyHxS3aWZA+5/2q+SMMC
JMAjs/3L0ceLqt4aA9Tqx2s/e68Hse+i71gQdxkCgYBlwXvB5lqcntDds/uJktUh
xJwqd+tOp7R1Digqhd70J7UiL45iDju1O+AeAphvFB5ata1xbUuzt4EJJNcHt2ht
qxUqpaxtyheEFUOHTQ4FCKQJeFOBBWV5iurYT00P0hhkbPSFKENaPP2YKIMk6M+A
9qVkdfrH7HwLJp1gYPHVqwKBgDt1/5k/Gu04q7kZ+LDs2C51bXKvazxVkzj+KHOq
5hmPBPCp4c+vDQwldZxN+kF+Q8P8+TXiSuRkc2V3ScavZOlm39IOwpjR5OtETaTi
AuNliGgnJl7SpRJ+UZlOxdjZLOjTz9HnU5VsFQGCz7fIzeFU20xGuiVgkohzhxHT
4uLJAoGAX1R7rbSEA9xFyZx9Pe6/lsYuBif9SGikgDuSypUzdYDUsuYUFI4mXxcg
rwpp6PhesAZV/Mhx7Nqcxz98ffZLOBrAsr5xtwVUQip284JbrdPLKwHU8l1hH+de
yXhN7eN1XwlMGT1Q2FwJ7YOiC7dgj0RoftAcUrId1LbB96wKOzo=
-----END RSA PRIVATE KEY-----
''';

void main() {
  check('PKCS#8: podpis = openssl', Jwt.rs256(claims, pkcs8) == vector);
  check('PKCS#1: podpis = openssl', Jwt.rs256(claims, pkcs1) == vector);
  check('PEM z końcami linii CRLF',
      Jwt.rs256(claims, pkcs8.replaceAll('\n', '\r\n')) == vector);
  var error = false;
  try {
    Jwt.rsaKey('-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----');
  } on FormatException {
    error = true;
  }
  check('śmieci zamiast klucza → FormatException', error);
  try {
    Jwt.rsaKey('nie klucz');
    error = false;
  } on FormatException {
    error = true;
  }
  check('brak PEM → FormatException', error);
}
