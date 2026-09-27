from PIL import Image
import numpy as np
import sys

def main():
    if len(sys.argv) != 4:
        print("Usage: python rgb-tool.py <image_path> <width> <height>")
        return

    image_path = sys.argv[1]
    width = int(sys.argv[2])
    height = int(sys.argv[3])

    img = Image.open(image_path)
    img = img.resize((width, height))
    img = img.transpose(method=Image.Transpose.FLIP_LEFT_RIGHT)
    img = img.transpose(method=Image.Transpose.FLIP_TOP_BOTTOM)
    rgb_array = np.array(img)

    for rgb_row in rgb_array:
      for rgb in rgb_row:
        rgb_888 = (rgb / 255.) * 0xff
        print(format((int(rgb_888[0]) << 16) | (int(rgb_888[1]) << 8) | (int(rgb_888[2]) << 0), '06x'))


if __name__ == "__main__":
    main()

