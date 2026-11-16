# tests/test_microsoft_downloader.py
# Unit and integration tests for Microsoft Direct Downloader
# Maintainer: NggKhaiz | automation credit: kelexine | original builder: ntdevlabs

import os
import sys
import pytest
from unittest.mock import MagicMock, patch, call

# Ensure scripts directory is in python path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../scripts')))

from microsoft_direct_downloader import MicrosoftPlaywrightDownloader


class TestMicrosoftPlaywrightDownloader:
    
    def test_user_agent_rotation(self):
        """Test that user agents rotate correctly and reshuffle when exhausted"""
        downloader = MicrosoftPlaywrightDownloader()
        
        # Test initial pool size
        assert len(downloader.USER_AGENTS) == 10
        
        # Collect 10 rotated agents
        collected_agents = []
        for _ in range(10):
            collected_agents.append(downloader._get_next_user_agent())
            
        # Ensure all 10 are unique and exist in original list
        assert len(set(collected_agents)) == 10
        assert all(agent in downloader.USER_AGENTS for agent in collected_agents)
        
        # Next selection should trigger a pool reshuffle and reset index to 0
        next_agent = downloader._get_next_user_agent()
        assert next_agent in downloader.USER_AGENTS

    @patch('time.sleep')
    def test_random_delay(self, mock_sleep):
        """Test that random delay falls within the configured min/max boundaries"""
        downloader = MicrosoftPlaywrightDownloader(min_delay=1.5, max_delay=3.5)
        
        # Test with configured values
        downloader._random_delay()
        mock_sleep.assert_called_once()
        delay_called = mock_sleep.call_args[0][0]
        assert 1.5 <= delay_called <= 3.5
        
        # Test with overrides
        mock_sleep.reset_mock()
        downloader._random_delay(min_override=0.1, max_override=0.2)
        mock_sleep.assert_called_once()
        delay_called = mock_sleep.call_args[0][0]
        assert 0.1 <= delay_called <= 0.2

    @patch('microsoft_direct_downloader.sync_playwright')
    @patch('time.sleep')
    def test_get_windows11_link_success_dynamic_option(self, mock_sleep, mock_sync_playwright):
        """Test happy path where dynamic option iteration matches product edition option text"""
        # Mock Playwright layout
        mock_playwright = MagicMock()
        mock_sync_playwright.return_value.__enter__.return_value = mock_playwright
        
        mock_browser = MagicMock()
        mock_playwright.chromium.launch.return_value = mock_browser
        
        mock_context = MagicMock()
        mock_browser.new_context.return_value = mock_context
        
        mock_page = MagicMock()
        mock_context.new_page.return_value = mock_page
        
        # Setup mock options under `#product-edition option`
        mock_option_select = MagicMock()
        mock_option_select.get_attribute.return_value = "3321"
        mock_option_select.text_content.return_value = "Windows 11 (multi-edition ISO for x64 devices)"
        
        mock_option_other = MagicMock()
        mock_option_other.get_attribute.return_value = ""
        mock_option_other.text_content.return_value = "Select Download"
        
        mock_page.locator.return_value.all.side_effect = lambda: [mock_option_other, mock_option_select]
        
        # Setup mock languages
        mock_page.locator.return_value.all_text_contents.return_value = ["English (United States)", "French", "Spanish"]
        
        # Setup mock download button locator
        mock_download_btn = MagicMock()
        mock_download_btn.get_attribute.return_value = "https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64.iso?t=123"
        mock_page.locator.return_value.filter.return_value.first = mock_download_btn
        
        downloader = MicrosoftPlaywrightDownloader(headless=True)
        link = downloader.get_windows11_link()
        
        # Verify result and Playwright interactions
        assert link == "https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64.iso?t=123"
        
        # Check navigated page
        mock_page.goto.assert_called_with(downloader.DOWNLOAD_PAGE, wait_until='domcontentloaded', timeout=60000)
        
        # Check product edition selection called with dynamic option value
        mock_page.select_option.assert_any_call('#product-edition', value='3321')
        mock_page.click.assert_any_call('#submit-product-edition')
        
        # Check language dropdown select by label
        mock_page.select_option.assert_any_call('#product-languages', label='English (United States)')
        mock_page.click.assert_any_call('#submit-sku')
        
        # Check closing cleanups
        mock_browser.close.assert_called_once()

    @patch('microsoft_direct_downloader.sync_playwright')
    @patch('time.sleep')
    def test_get_windows11_link_fallback_value_3321(self, mock_sleep, mock_sync_playwright):
        """Test fallback path where dynamic option lookup throws but value '3321' fallback works"""
        mock_playwright = MagicMock()
        mock_sync_playwright.return_value.__enter__.return_value = mock_playwright
        
        mock_browser = MagicMock()
        mock_playwright.chromium.launch.return_value = mock_browser
        
        mock_context = MagicMock()
        mock_browser.new_context.return_value = mock_context
        
        mock_page = MagicMock()
        mock_context.new_page.return_value = mock_page
        
        # Dynamic search throws an exception
        mock_page.locator.side_effect = Exception("Locator timed out")
        
        # Setup language selection mock
        mock_page.locator.return_value.all_text_contents.return_value = ["English (United States)"]
        
        # Setup mock download button locator
        mock_download_btn = MagicMock()
        mock_download_btn.get_attribute.return_value = "https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64.iso?t=123"
        
        # Restore mock page locator for normal selectors
        def locator_se(selector):
            mock_loc = MagicMock()
            if selector == 'a.btn.btn-primary':
                mock_loc.filter.return_value.first = mock_download_btn
                return mock_loc
            elif selector == '#product-languages option':
                mock_loc.all_text_contents.return_value = ["English (United States)"]
                return mock_loc
            return mock_loc
            
        mock_page.locator.side_effect = locator_se
        
        # Select option behavior: succeed for value='3321'
        def select_option_se(selector, value=None, label=None):
            if selector == '#product-edition' and value == '3321':
                return
            elif selector == '#product-languages' and label == 'English (United States)':
                return
            raise Exception("Option not found")
            
        mock_page.select_option.side_effect = select_option_se
        
        downloader = MicrosoftPlaywrightDownloader()
        link = downloader.get_windows11_link()
        
        # Verify success and check that 3321 fallback was attempted
        assert link == "https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64.iso?t=123"
        mock_page.select_option.assert_any_call('#product-edition', value='3321')

    @patch('microsoft_direct_downloader.sync_playwright')
    @patch('time.sleep')
    def test_get_windows11_link_total_failure(self, mock_sleep, mock_sync_playwright):
        """Test complete failure when all selection and fallback methods raise exceptions"""
        mock_playwright = MagicMock()
        mock_sync_playwright.return_value.__enter__.return_value = mock_playwright
        
        mock_browser = MagicMock()
        mock_playwright.chromium.launch.return_value = mock_browser
        
        mock_context = MagicMock()
        mock_browser.new_context.return_value = mock_context
        
        mock_page = MagicMock()
        mock_context.new_page.return_value = mock_page
        
        # Every select option fails
        mock_page.select_option.side_effect = Exception("Select error")
        mock_page.locator.side_effect = Exception("Locator error")
        
        downloader = MicrosoftPlaywrightDownloader()
        link = downloader.get_windows11_link()
        
        # Ensure it handles clean error catching and returns None
        assert link is None
        mock_browser.close.assert_not_called()  # Inside enter block browser could remain open on unhandled or handled

    @patch('microsoft_direct_downloader.sync_playwright')
    def test_browser_exception_does_not_log_signed_url(self, mock_sync_playwright, caplog):
        secret_url = "https://software.download.prss.microsoft.com/file.iso?signature=private-token"
        mock_playwright = MagicMock()
        mock_sync_playwright.return_value.__enter__.return_value = mock_playwright
        mock_page = mock_playwright.chromium.launch.return_value.new_context.return_value.new_page.return_value
        mock_page.goto.side_effect = RuntimeError(secret_url)

        assert MicrosoftPlaywrightDownloader().get_windows11_link() is None
        assert "private-token" not in caplog.text
        assert "signature=private" not in caplog.text

    def test_get_all_versions_parsing(self):
        """Test extraction of version and build number details from a valid download URL"""
        downloader = MicrosoftPlaywrightDownloader()
        
        # Mock get_windows11_link to return a dynamic ISO download URL containing 25H2 and build numbers
        mock_iso_url = (
            "https://software.download.prss.microsoft.com/dbazure/"
            "Win11_25H2_26100.1742_English_x64_v2.iso?t=64d33240"
        )
        
        with patch.object(downloader, 'get_windows11_link', return_value=mock_iso_url), \
                patch.object(downloader, '_get_iso_validator', return_value='"etag-1"|Wed, 01 Oct 2026 00:00:00 GMT|123456789'):
            versions = downloader.get_all_versions()
            
            assert len(versions) == 1
            entry = versions[0]
            assert entry['version'] == '25H2'
            assert entry['build_number'] == '26100.1742'
            assert entry['iso_url'] == mock_iso_url
            assert entry['architecture'] == 'amd64'
            assert entry['source'] == 'microsoft_playwright'
            assert entry['build_id'].startswith('msft-playwright-25h2-')
            assert entry['iso_fingerprint'].startswith('"etag-1"')

    def test_stable_build_id_ignores_expiring_signed_query(self):
        downloader = MicrosoftPlaywrightDownloader()
        url_a = 'https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64_v2.iso?build=26100.1742&t=short-a&P1=old'
        url_b = 'https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64_v2.iso?build=99999.9&t=short-b&P1=new'

        with patch.object(downloader, 'get_windows11_link', side_effect=[url_a, url_b]), \
                patch.object(downloader, '_get_iso_validator', return_value='etag|last-modified|123'):
            first = downloader.get_all_versions()[0]
            second = downloader.get_all_versions()[0]

        assert first['build_id'] == second['build_id']
        assert first['iso_url'] != second['iso_url']
        assert first['build_number'] == second['build_number'] == 'Latest'

    def test_changed_remote_validator_creates_new_build_id(self):
        downloader = MicrosoftPlaywrightDownloader()
        url = 'https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64_v2.iso?t=short'

        with patch.object(downloader, 'get_windows11_link', return_value=url), \
                patch.object(downloader, '_get_iso_validator', side_effect=['etag-old', 'etag-new']):
            first = downloader.get_all_versions()[0]
            second = downloader.get_all_versions()[0]

        assert first['build_id'] != second['build_id']


    def test_rejects_microsoft_host_with_userinfo_or_unapproved_port(self):
        downloader = MicrosoftPlaywrightDownloader()
        unsafe_urls = [
            'https://user:password@software.download.prss.microsoft.com/dbazure/Win11_25H2_x64.iso',
            'https://software.download.prss.microsoft.com:8443/dbazure/Win11_25H2_x64.iso',
        ]
        for unsafe_url in unsafe_urls:
            with patch.object(downloader, 'get_windows11_link', return_value=unsafe_url), \
                    patch.object(downloader, '_get_iso_validator') as validator:
                assert downloader.get_all_versions() == []
                validator.assert_not_called()

    def test_rejects_non_microsoft_iso_url(self):
        downloader = MicrosoftPlaywrightDownloader()
        with patch.object(downloader, 'get_windows11_link', return_value='https://example.invalid/Win11_25H2_x64.iso'), \
                patch.object(downloader, '_get_iso_validator') as validator:
            assert downloader.get_all_versions() == []
        validator.assert_not_called()
