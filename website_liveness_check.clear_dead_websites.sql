-- Clears the website field for 27 churches whose stored URL was confirmed
-- dead by a real HTTP check (DNS failure, connection refused/reset, timeout,
-- expired/invalid TLS certificate, or a genuine 404/500/503 response), run
-- twice: an initial pass, then a careful retry with fuller browser-like
-- headers and a delayed third attempt before concluding anything was really
-- dead -- 25 other churches flagged in the first pass turned out to be
-- bot/WAF protection (a 403 to an automated request), not actually dead, and
-- are correctly NOT included here after recovering on retry.
--
-- Deliberately NOT included, even though they still returned 403 after the
-- same careful retry: Randolph Christian Church, Lilly of the Valley
-- Missionary Baptist Church, Southern Baptists of Texas Convention Inc,
-- Whole Life Christian Church, Our Lady of Guadalupe Parish, Westside
-- Fellowship Church Inc, New Braunfels Christian Ministries -- a 403 can
-- never be fully distinguished from bot/WAF protection on a genuinely live
-- site by a plain HTTP client (a Cloudflare JS challenge, for instance,
-- cannot be solved without executing JavaScript), and at least two of these
-- (a state Baptist convention, a real Catholic parish) are almost certainly
-- live. Recommend a quick manual check on these 7 rather than clearing them
-- automatically.
--
-- Also NOT included: 13 Facebook-page URLs (facebook.com blocks essentially
-- all automated requests regardless of whether the page exists, so this
-- method cannot verify them one way or the other), and 3 internal/test
-- church records ("Test 2", "Test 2 church", "Test 4") plus one church
-- (Catholic Church of San Antonio) whose website is a literal "test.com"
-- placeholder from earlier manual testing this session -- not real church
-- data, so out of scope for a real-website correction regardless of
-- liveness.

-- ENOTFOUND: http://www.alamostone.org/
UPDATE churches SET website = NULL WHERE id = 'dd29a8c9-08d1-4b06-834e-4e8b41486d2e' AND name = 'Alamo Stone Church';

-- ECONNREFUSED: https://www.feedmysheepsa.com/
UPDATE churches SET website = NULL WHERE id = 'c33b1fd5-b4c6-4408-827a-07667de658a3' AND name = 'Believers in Christ Ministries of San Antonio';

-- ENOTFOUND: http://www.calvarycrossag.com/contact-us/
UPDATE churches SET website = NULL WHERE id = '56981617-73d1-4823-b675-ec3553fb29de' AND name = 'Calvary Cross Church of the Assemblies of God';

-- ENOTFOUND: http://imadefector.com/
UPDATE churches SET website = NULL WHERE id = '0b257bee-ab71-4c4f-9079-02df9c8ad5ff' AND name = 'Defection Church Inc';

-- http_503: https://lffcsa.org/
UPDATE churches SET website = NULL WHERE id = 'de5efb7a-663b-4f15-8cb8-f8d18cb1a4a6' AND name = 'Faith Gospel Fellowship Church';

-- http_404: https://www.faith4liferc.cc/
UPDATE churches SET website = NULL WHERE id = '6af0c253-b71c-44d3-abb0-7a332db7e80b' AND name = 'Glorious Pentecostal Church';

-- UND_ERR_CONNECT_TIMEOUT: http://www.iamgtc.org/
UPDATE churches SET website = NULL WHERE id = 'bed70f0c-d0c5-4b8e-ad83-07fc6c12d56d' AND name = 'Grace Tabernacle Ph Church';

-- ENOTFOUND: http://greaterfaithministriessa.com/
UPDATE churches SET website = NULL WHERE id = 'df49671d-a354-4d72-b25c-f71dc69cf4b2' AND name = 'Greater Faith Ministries';

-- ENOTFOUND: https://harlandalemethodistchurch.com/
UPDATE churches SET website = NULL WHERE id = 'f97d9943-46c7-40bb-bda9-45298dbc95e5' AND name = 'Harlandale United Methodist Church';

-- ENOTFOUND: http://www.wegivehopesa.org/
UPDATE churches SET website = NULL WHERE id = 'c331035a-bd93-4f0a-8272-1020cca2d591' AND name = 'Hope House Ministries';

-- ENOTFOUND: http://www.iglesiacristianashammah.com/
UPDATE churches SET website = NULL WHERE id = '11b5ee84-fc0e-4db3-a7f1-18ab084899ac' AND name = 'Iglesia Cristiana Jehova Jireh';

-- ENOTFOUND: http://www.iglesiacristianashammah.com/
UPDATE churches SET website = NULL WHERE id = '51d1b17f-e299-448f-b464-36fb2ae37603' AND name = 'Iglesia Cristiana Jehova Shammah';

-- ENOTFOUND: http://www.palabramielsanantonio.com/
UPDATE churches SET website = NULL WHERE id = 'ad297dc4-8aec-477e-b5a8-65cecffaa02b' AND name = 'Iglesia De Jesucristo Palabra Miel Montesion';

-- http_404: http://www.jemirsa.org/
UPDATE churches SET website = NULL WHERE id = '2dc6693e-28ec-481c-b6aa-6d1fdff8d2d5' AND name = 'Iglesia Jesucristo Es Mi Refugio De San Antonio';

-- ENOTFOUND: https://www.ithchurch.com/
UPDATE churches SET website = NULL WHERE id = '280ea895-e031-440e-b7ba-9f996064cc88' AND name = 'Igniting the Harvest Christian Church Inc';

-- ERR_TLS_CERT_ALTNAME_INVALID: https://klemalife.church/
UPDATE churches SET website = NULL WHERE id = 'c26e574b-1b14-4225-a66d-c9cc2b04e8b0' AND name = 'Klema Life Church';

-- ERR_SSL_SSL/TLS_ALERT_HANDSHAKE_FAILURE: https://mylivingwater.church/
UPDATE churches SET website = NULL WHERE id = '7a7a9600-9052-44c8-b9ea-a5364565d88f' AND name = 'Living Water Community Church San Antonio Inc';

-- http_500: https://masvidasa.com/
UPDATE churches SET website = NULL WHERE id = '837d6ada-ec64-4f6f-b972-f43082e543ea' AND name = 'Mas Vida Iglesia Cristiana';

-- ECONNREFUSED: https://www.ncfellowship.church/
UPDATE churches SET website = NULL WHERE id = '8ff42e56-ca3b-4a7b-beb5-f8e9e4faf502' AND name = 'North Central Fellowship';

-- UNABLE_TO_GET_ISSUER_CERT_LOCALLY: https://www.omsmi.org/pastoral-counseling
UPDATE churches SET website = NULL WHERE id = '2a6323af-9d68-406d-b94d-75f26f5dace7' AND name = 'Order My Steps Ministries International Inc';

-- ENOTFOUND: https://www.reflectionofchrist.org/
UPDATE churches SET website = NULL WHERE id = '69f94743-0f1e-4f1d-b1e4-398f4d122041' AND name = 'Reflection of Christ Ministry';

-- ECONNRESET: https://seasonchurch.org/
UPDATE churches SET website = NULL WHERE id = 'a6ae668c-4060-4f38-9d37-becea082c968' AND name = 'Season Church Inc';

-- ENOTFOUND: http://stceciliasa.org/
UPDATE churches SET website = NULL WHERE id = '79f4dd78-6f6f-44ad-8b29-de7b2947a21e' AND name = 'St Cecilias Catholic Church';

-- ENOTFOUND: http://www.wegivehopesa.org/
UPDATE churches SET website = NULL WHERE id = 'b31ba2b1-dbe5-43a6-a82e-4bdc11803406' AND name = 'Star of Hope Ministries';

-- ENOTFOUND: http://starlightmiseionarybaptistsatx.org/
UPDATE churches SET website = NULL WHERE id = 'e4496140-2610-4ae7-b85a-b0bad2bfcd29' AND name = 'Starlight Baptist Church';

-- http_404: http://www.unityofthefaithcmi.com/
UPDATE churches SET website = NULL WHERE id = 'b87fa587-6ae7-476e-9283-114239028d97' AND name = 'Unity of Faith Christian Ministries International';

-- CERT_HAS_EXPIRED: http://www.wccofsa.org/
UPDATE churches SET website = NULL WHERE id = 'bb93956c-e591-44eb-a75b-c6585b03b2cf' AND name = 'Woodlawn Christian Church';
