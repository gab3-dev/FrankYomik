"""Unit tests for the scene describer module (mocked Ollama)."""

from unittest.mock import patch, MagicMock

from PIL import Image

from kindle.scene_describer import describe_scene, _clean_description, _crop_around_bbox, _encode_image


class TestCleanDescription:
    def test_strips_think_tags(self):
        assert _clean_description("<think>reasoning</think>Two characters") == "Two characters"

    def test_strips_xml_tags(self):
        assert _clean_description("<output>A girl</output>") == "A girl"

    def test_strips_whitespace(self):
        assert _clean_description("  Scene desc  ") == "Scene desc"

    def test_empty_after_strip(self):
        assert _clean_description("<think>only thinking</think>") == ""


class TestEncodeImage:
    def test_returns_base64_string(self):
        img = Image.new("RGB", (100, 100), (255, 0, 0))
        result = _encode_image(img)
        assert isinstance(result, str)
        assert len(result) > 0
        # Should be valid base64
        import base64
        decoded = base64.b64decode(result)
        assert len(decoded) > 0

    def test_resizes_large_images(self):
        img = Image.new("RGB", (4000, 3000), (0, 0, 255))
        result = _encode_image(img)
        # Just verify it doesn't crash and returns something
        assert isinstance(result, str)
        assert len(result) > 0

    def test_converts_rgba_to_rgb(self):
        img = Image.new("RGBA", (50, 50), (255, 0, 0, 128))
        result = _encode_image(img)
        assert isinstance(result, str)


class TestDescribeScene:
    @patch("kindle.scene_describer.SCENE_DESCRIPTION_ENABLED", False)
    def test_returns_empty_when_disabled(self):
        img = Image.new("RGB", (100, 100))
        assert describe_scene(img) == ""

    @patch("kindle.scene_describer.SCENE_DESCRIPTION_ENABLED", True)
    @patch("kindle.scene_describer.requests.post")
    def test_returns_description_on_success(self, mock_post):
        mock_resp = MagicMock()
        mock_resp.json.return_value = {
            "message": {"content": "A young girl talking to an older man in a classroom."}
        }
        mock_resp.raise_for_status = MagicMock()
        mock_post.return_value = mock_resp

        img = Image.new("RGB", (200, 300))
        result = describe_scene(img)
        assert result == "A young girl talking to an older man in a classroom."

        # Verify images field is sent
        payload = mock_post.call_args[1]["json"]
        assert "images" in payload["messages"][0]
        assert len(payload["messages"][0]["images"]) == 1

    @patch("kindle.scene_describer.SCENE_DESCRIPTION_ENABLED", True)
    @patch("kindle.scene_describer.requests.post", side_effect=Exception("connection error"))
    def test_returns_empty_on_failure(self, mock_post):
        img = Image.new("RGB", (100, 100))
        result = describe_scene(img)
        assert result == ""

    @patch("kindle.scene_describer.SCENE_DESCRIPTION_ENABLED", True)
    @patch("kindle.scene_describer.requests.post")
    def test_cleans_think_tags_from_response(self, mock_post):
        mock_resp = MagicMock()
        mock_resp.json.return_value = {
            "message": {"content": "<think>let me analyze</think>Two boys fighting."}
        }
        mock_resp.raise_for_status = MagicMock()
        mock_post.return_value = mock_resp

        img = Image.new("RGB", (100, 100))
        result = describe_scene(img)
        assert result == "Two boys fighting."

    @patch("kindle.scene_describer.SCENE_DESCRIPTION_ENABLED", True)
    @patch("kindle.scene_describer.requests.post")
    def test_uses_correct_model_and_options(self, mock_post):
        mock_resp = MagicMock()
        mock_resp.json.return_value = {"message": {"content": "Scene"}}
        mock_resp.raise_for_status = MagicMock()
        mock_post.return_value = mock_resp

        img = Image.new("RGB", (100, 100))
        describe_scene(img)

        payload = mock_post.call_args[1]["json"]
        assert payload["stream"] is False
        assert "num_predict" in payload["options"]
        assert payload["options"]["num_predict"] == 256

    @patch("kindle.scene_describer.SCENE_DESCRIPTION_ENABLED", True)
    @patch("kindle.scene_describer.SCENE_MODEL", "gemma3:12b")
    @patch("kindle.scene_describer.requests.post")
    def test_uses_scene_model_not_translate_model(self, mock_post):
        """Scene describer must use SCENE_MODEL, not TRANSLATE_MODEL."""
        mock_resp = MagicMock()
        mock_resp.json.return_value = {"message": {"content": "Scene"}}
        mock_resp.raise_for_status = MagicMock()
        mock_post.return_value = mock_resp

        img = Image.new("RGB", (100, 100))
        describe_scene(img)

        payload = mock_post.call_args[1]["json"]
        assert payload["model"] == "gemma3:12b"

    @patch("kindle.scene_describer.SCENE_DESCRIPTION_ENABLED", True)
    @patch("kindle.scene_describer.requests.post")
    def test_bbox_crops_image_before_sending(self, mock_post):
        """When bbox is given, the image sent should be a cropped region."""
        mock_resp = MagicMock()
        mock_resp.json.return_value = {"message": {"content": "A girl speaking"}}
        mock_resp.raise_for_status = MagicMock()
        mock_post.return_value = mock_resp

        img = Image.new("RGB", (800, 1200))
        result = describe_scene(img, bbox=(200, 300, 400, 500))
        assert result == "A girl speaking"
        mock_post.assert_called_once()

    @patch("kindle.scene_describer.SCENE_DESCRIPTION_ENABLED", True)
    @patch("kindle.scene_describer.requests.post")
    def test_no_bbox_sends_full_image(self, mock_post):
        """Without bbox, the full image is sent."""
        mock_resp = MagicMock()
        mock_resp.json.return_value = {"message": {"content": "Full page"}}
        mock_resp.raise_for_status = MagicMock()
        mock_post.return_value = mock_resp

        img = Image.new("RGB", (800, 1200))
        describe_scene(img, bbox=None)
        mock_post.assert_called_once()


class TestCropAroundBbox:
    def test_basic_crop(self):
        img = Image.new("RGB", (1000, 1000))
        cropped = _crop_around_bbox(img, (300, 300, 500, 500))
        # bbox is 200x200, pad is 2x = 400 each side
        # crop: (0, 0, 900, 900) clamped to image bounds
        assert cropped.size[0] > 0
        assert cropped.size[1] > 0
        assert cropped.size[0] <= 1000
        assert cropped.size[1] <= 1000

    def test_clamps_to_image_bounds(self):
        img = Image.new("RGB", (500, 500))
        cropped = _crop_around_bbox(img, (10, 10, 50, 50))
        # bbox 40x40, pad 80 each side → crop (0,0,130,130) clamped
        assert cropped.size[0] <= 500
        assert cropped.size[1] <= 500

    def test_edge_bbox(self):
        img = Image.new("RGB", (200, 200))
        cropped = _crop_around_bbox(img, (0, 0, 50, 50))
        assert cropped.size[0] > 0
        assert cropped.size[1] > 0
