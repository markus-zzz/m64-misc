from PIL import Image
import numpy as np
import sys

def main():
    if len(sys.argv) != 5:
        print("Usage: python rgb-tool.py <image_path> <width> <height> <output_file>")
        return

    image_path = sys.argv[1]
    width = int(sys.argv[2])
    height = int(sys.argv[3])
    output_path = sys.argv[4]

    img = Image.open(image_path)
    img = img.resize((width, height))
    img = img.transpose(method=Image.Transpose.FLIP_LEFT_RIGHT)
    img = img.transpose(method=Image.Transpose.FLIP_TOP_BOTTOM)
    rgb_array = np.array(img.convert("RGB"), dtype=np.uint32)

    # One little-endian 32-bit word per pixel: 0x00RRGGBB
    words = (rgb_array[:, :, 1] << 16) | (rgb_array[:, :, 0] << 8) | rgb_array[:, :, 2]
    with open(output_path, "wb") as f:
        f.write(words.astype("<u4").tobytes())


if __name__ == "__main__":
    main()

