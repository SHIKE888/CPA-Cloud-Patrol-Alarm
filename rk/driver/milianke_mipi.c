/*
 * Milianke virtual MIPI CSI-2 sensor driver for FPGA video source.
 */

#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of_graph.h>
#include <linux/slab.h>
#include <linux/version.h>
#include <linux/compat.h>
#include <media/media-entity.h>
#include <media/v4l2-async.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-fwnode.h>
#include <media/v4l2-mediabus.h>
#include <media/v4l2-subdev.h>

#ifndef RKMODULE_API_VERSION
#define RKMODULE_NAME_LEN 32
#define RKMODULE_LSCDATA_LEN 289
#define RKMODULE_HDR_NONE 0x00
#define RKMODULE_HDR_X2 0x05
#define RKMODULE_HDR_X3 0x06

struct rkmodule_base_inf
{
    char sensor[RKMODULE_NAME_LEN];
    char module[RKMODULE_NAME_LEN];
    char lens[RKMODULE_NAME_LEN];
};

struct rkmodule_inf
{
    struct rkmodule_base_inf base;
    /* other fields (fuse/awb/af/lsc) unused here */
    char reserved[2048];
};

struct rkmodule_hdr_cfg
{
    __u32 hdr_mode;
    __u32 esp[8];
};

#define RKMODULE_GET_MODULE_INFO _IOR('W', 0x03, struct rkmodule_inf)
#define RKMODULE_GET_HDR_CFG _IOR('W', 0x0b, struct rkmodule_hdr_cfg)
#define RKMODULE_SET_HDR_CFG _IOW('W', 0x0c, struct rkmodule_hdr_cfg)
#define RKMODULE_SET_QUICK_STREAM _IOW('W', 0x0d, __u32)
#endif

#define DUMMY_WIDTH 1920
#define DUMMY_HEIGHT 1080
#define DUMMY_FPS_NUM 1
#define DUMMY_FPS_DEN 60

#define DUMMY_LINK_FREQ 500000000
/* 100 MHz × 2 × 4 lane / 16 bpp = 50,000,000 pixels/s */
#define DUMMY_PIXEL_RATE 148500000

static bool always_on = true;
module_param(always_on, bool, 0644);
MODULE_PARM_DESC(always_on,
                 "Assert mipi-en GPIO at probe so FPGA starts HS before DPHY (default: true)");

static const s64 link_freq_menu[] = {DUMMY_LINK_FREQ};

struct milianke_mipi
{
    struct v4l2_subdev subdev;
    struct media_pad pad;
    struct v4l2_ctrl_handler ctrl_handler;
    struct v4l2_ctrl *link_freq;
    struct v4l2_ctrl *pixel_rate;
    struct v4l2_ctrl *vblank;
    struct mutex mutex;
    struct gpio_desc *mipi_en_gpio;
    bool streaming;
    const char *module_name;
    const char *lens_name;
    const char *module_facing;
    u32 module_index;
};

static int milianke_g_volatile_ctrl(struct v4l2_ctrl *ctrl)
{
    switch (ctrl->id)
    {
    case V4L2_CID_LINK_FREQ:
        ctrl->val = 0;
        break;
    case V4L2_CID_PIXEL_RATE:
        ctrl->val = DUMMY_PIXEL_RATE;
        break;
    default:
        return -EINVAL;
    }

    return 0;
}

static const struct v4l2_ctrl_ops milianke_ctrl_ops = {
    .g_volatile_ctrl = milianke_g_volatile_ctrl,
};

static int milianke_enum_mbus_code(struct v4l2_subdev *sd,
                                   struct v4l2_subdev_state *state,
                                   struct v4l2_subdev_mbus_code_enum *code)
{
    if (code->index > 0)
        return -EINVAL;

    code->code = MEDIA_BUS_FMT_YUYV8_2X8;

    return 0;
}

static int milianke_enum_frame_size(struct v4l2_subdev *sd,
                                    struct v4l2_subdev_state *state,
                                    struct v4l2_subdev_frame_size_enum *fse)
{
    if (fse->index > 0)
        return -EINVAL;

    fse->min_width = DUMMY_WIDTH;
    fse->max_width = DUMMY_WIDTH;
    fse->min_height = DUMMY_HEIGHT;
    fse->max_height = DUMMY_HEIGHT;

    return 0;
}

static int milianke_get_fmt(struct v4l2_subdev *sd,
                            struct v4l2_subdev_state *state,
                            struct v4l2_subdev_format *fmt)
{
    fmt->format.width = DUMMY_WIDTH;
    fmt->format.height = DUMMY_HEIGHT;
    fmt->format.code = MEDIA_BUS_FMT_YUYV8_2X8;
    fmt->format.field = V4L2_FIELD_NONE;
    /*
     * ==== 色彩空间（重要，改过） ====
     *
     * FPGA 端 rgb_to_yuv422_quad.v 用的是 **BT.709 + limited range**：
     *     Y = 0.183R + 0.614G + 0.062B + 16
     * 系数和 0.859 = 219/255，且 (0.183,0.614,0.062) 与 BT.709 的
     * (0.2126,0.7152,0.0722) x 219/255 吻合；抓帧实测 Y 范围 22~234
     * （limited 白点 = 235）。所以黑点=16、白点=235。
     *
     * 原来这里写的是 V4L2_COLORSPACE_SRGB，而 sRGB 的默认 quantization 是
     * **full range(0~255)**，导致 rkcif/rkisp 把 limited 数据当 full 处理：
     * 黑电平被抬到 16/255、白点只到 235、色度欠饱和 —— 画面发灰、发绿、
     * 颜色很怪（HDMI / kmssink 输出同样受影响）。
     *
     * 改成 REC709 + LIM_RANGE 后整条 RK 侧链路（ISP -> VPSS -> kmssink/HDMI）
     * 都会按正确的方式做 YUV->RGB。
     */
    fmt->format.colorspace = V4L2_COLORSPACE_REC709;
    fmt->format.ycbcr_enc = V4L2_YCBCR_ENC_709;
    fmt->format.quantization = V4L2_QUANTIZATION_LIM_RANGE;
    fmt->format.xfer_func = V4L2_XFER_FUNC_709;

    return 0;
}

static int milianke_set_fmt(struct v4l2_subdev *sd,
                            struct v4l2_subdev_state *state,
                            struct v4l2_subdev_format *fmt)
{
    return milianke_get_fmt(sd, state, fmt);
}

static int milianke_enum_frame_interval(struct v4l2_subdev *sd,
                                        struct v4l2_subdev_state *state,
                                        struct v4l2_subdev_frame_interval_enum *fie)
{
    if (fie->index > 0)
        return -EINVAL;

    fie->width = DUMMY_WIDTH;
    fie->height = DUMMY_HEIGHT;
    fie->code = MEDIA_BUS_FMT_YUYV8_2X8;
    fie->interval.numerator = DUMMY_FPS_NUM;
    fie->interval.denominator = DUMMY_FPS_DEN;

    return 0;
}

static int milianke_g_frame_interval(struct v4l2_subdev *sd,
                                     struct v4l2_subdev_frame_interval *fi)
{
    fi->interval.numerator = DUMMY_FPS_NUM;
    fi->interval.denominator = DUMMY_FPS_DEN;

    return 0;
}

static int milianke_g_mbus_config(struct v4l2_subdev *sd, unsigned int pad,
                                  struct v4l2_mbus_config *config)
{
    if (!config)
        return -EINVAL;

    memset(config, 0, sizeof(*config));
    config->type = V4L2_MBUS_CSI2_DPHY;
    config->bus.mipi_csi2.num_data_lanes = 4;
    /* Continuous clock = absence of NONCONTINUOUS flag; keep 0. */
    config->bus.mipi_csi2.flags = 0;

    return 0;
}

static int milianke_s_stream(struct v4l2_subdev *sd, int on)
{
    struct milianke_mipi *sensor =
        container_of(sd, struct milianke_mipi, subdev);

    mutex_lock(&sensor->mutex);
    if (sensor->mipi_en_gpio)
    {

        gpiod_set_value_cansleep(sensor->mipi_en_gpio, on ? 1 : 0);
    }
    sensor->streaming = !!on;
    mutex_unlock(&sensor->mutex);

    dev_info(sd->dev, "s_stream(%d): mipi-en GPIO toggled %s\n",
             on, on ? "HIGH" : "LOW");
    return 0;
}

static int milianke_s_power(struct v4l2_subdev *sd, int on)
{
    /* No power rails to toggle; GPIO handled in s_stream. */
    dev_dbg(sd->dev, "s_power(%d)\n", on);
    return 0;
}

static long milianke_priv_ioctl(struct v4l2_subdev *sd, unsigned int cmd,
                                void *arg)
{
    struct milianke_mipi *sensor =
        container_of(sd, struct milianke_mipi, subdev);
    struct rkmodule_inf *inf;
    struct rkmodule_hdr_cfg *hdr;
    u32 *stream;

    switch (cmd)
    {
    case RKMODULE_GET_MODULE_INFO:
        inf = arg;
        if (!inf)
            return -EINVAL;
        memset(inf, 0, sizeof(*inf));
        strscpy(inf->base.sensor, "FPGA-MIPI",
                sizeof(inf->base.sensor));
        if (sensor->module_name)
            strscpy(inf->base.module, sensor->module_name,
                    sizeof(inf->base.module));
        if (sensor->lens_name)
            strscpy(inf->base.lens, sensor->lens_name,
                    sizeof(inf->base.lens));
        return 0;
    case RKMODULE_GET_HDR_CFG:
        hdr = arg;
        if (!hdr)
            return -EINVAL;
        memset(hdr, 0, sizeof(*hdr));
        hdr->hdr_mode = RKMODULE_HDR_NONE;
        return 0;
    case RKMODULE_SET_HDR_CFG:
        hdr = arg;
        if (!hdr)
            return -EINVAL;
        if (hdr->hdr_mode != RKMODULE_HDR_NONE)
            return -EINVAL;
        return 0;
    case RKMODULE_SET_QUICK_STREAM:
        stream = arg;
        if (!stream)
            return -EINVAL;
        return milianke_s_stream(sd, *stream);
    default:
        return -ENOIOCTLCMD;
    }
}

#ifdef CONFIG_COMPAT
static long milianke_priv_compat_ioctl(struct v4l2_subdev *sd, unsigned int cmd,
                                       unsigned long arg)
{
    void __user *up = compat_ptr(arg);
    long ret;

    switch (cmd)
    {
    case RKMODULE_GET_MODULE_INFO:
    {
        struct rkmodule_inf *inf;

        inf = kzalloc(sizeof(*inf), GFP_KERNEL);
        if (!inf)
            return -ENOMEM;
        ret = milianke_priv_ioctl(sd, cmd, inf);
        if (!ret && copy_to_user(up, inf, sizeof(*inf)))
            ret = -EFAULT;
        kfree(inf);
        return ret;
    }
    case RKMODULE_GET_HDR_CFG:
    {
        struct rkmodule_hdr_cfg *hdr;

        hdr = kzalloc(sizeof(*hdr), GFP_KERNEL);
        if (!hdr)
            return -ENOMEM;
        ret = milianke_priv_ioctl(sd, cmd, hdr);
        if (!ret && copy_to_user(up, hdr, sizeof(*hdr)))
            ret = -EFAULT;
        kfree(hdr);
        return ret;
    }
    case RKMODULE_SET_HDR_CFG:
    {
        struct rkmodule_hdr_cfg hdr;

        if (copy_from_user(&hdr, up, sizeof(hdr)))
            return -EFAULT;
        return milianke_priv_ioctl(sd, cmd, &hdr);
    }
    case RKMODULE_SET_QUICK_STREAM:
    {
        u32 stream;

        if (copy_from_user(&stream, up, sizeof(stream)))
            return -EFAULT;
        return milianke_priv_ioctl(sd, cmd, &stream);
    }
    default:
        return -ENOIOCTLCMD;
    }
}
#endif

static const struct v4l2_subdev_core_ops milianke_core_ops = {
    .s_power = milianke_s_power,
    .ioctl = milianke_priv_ioctl,
#ifdef CONFIG_COMPAT
    .compat_ioctl32 = milianke_priv_compat_ioctl,
#endif
};

static const struct v4l2_subdev_pad_ops milianke_pad_ops = {
    .enum_mbus_code = milianke_enum_mbus_code,
    .enum_frame_size = milianke_enum_frame_size,
    .get_fmt = milianke_get_fmt,
    .set_fmt = milianke_set_fmt,
    .enum_frame_interval = milianke_enum_frame_interval,
    .get_mbus_config = milianke_g_mbus_config,
};

static const struct v4l2_subdev_video_ops milianke_video_ops = {
    .g_frame_interval = milianke_g_frame_interval,
    .s_stream = milianke_s_stream,
};

static const struct v4l2_subdev_ops milianke_subdev_ops = {
    .core = &milianke_core_ops,
    .pad = &milianke_pad_ops,
    .video = &milianke_video_ops,
};

static int milianke_probe(struct i2c_client *client,
                          const struct i2c_device_id *id)
{
    struct milianke_mipi *sensor;
    struct device_node *np = client->dev.of_node;
    struct v4l2_subdev *sd;
    char sd_name[V4L2_SUBDEV_NAME_SIZE];
    int ret;

    sensor = devm_kzalloc(&client->dev, sizeof(*sensor), GFP_KERNEL);
    if (!sensor)
        return -ENOMEM;

    if (np)
    {
        of_property_read_u32(np, "rockchip,camera-module-index",
                             &sensor->module_index);
        of_property_read_string(np, "rockchip,camera-module-facing",
                                &sensor->module_facing);
        of_property_read_string(np, "rockchip,camera-module-name",
                                &sensor->module_name);
        of_property_read_string(np, "rockchip,camera-module-lens-name",
                                &sensor->lens_name);
    }

    mutex_init(&sensor->mutex);

    sd = &sensor->subdev;
    v4l2_i2c_subdev_init(sd, client, &milianke_subdev_ops);
    sd->flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;

    snprintf(sd_name, sizeof(sd_name), "m%02d_%s_%s %s",
             sensor->module_index,
             sensor->module_facing ? sensor->module_facing : "b",
             sensor->module_name ? sensor->module_name : "fpga-mipi",
             dev_name(sd->dev));
    strscpy(sd->name, sd_name, sizeof(sd->name));

    sensor->pad.flags = MEDIA_PAD_FL_SOURCE;
    sd->entity.function = MEDIA_ENT_F_CAM_SENSOR;
    ret = media_entity_pads_init(&sd->entity, 1, &sensor->pad);
    if (ret)
        goto err_mutex;

    v4l2_ctrl_handler_init(&sensor->ctrl_handler, 3);
    sensor->link_freq = v4l2_ctrl_new_int_menu(&sensor->ctrl_handler,
                                               &milianke_ctrl_ops,
                                               V4L2_CID_LINK_FREQ,
                                               0, 0, link_freq_menu);
    if (sensor->link_freq)
        sensor->link_freq->flags |= V4L2_CTRL_FLAG_READ_ONLY;
    sensor->pixel_rate = v4l2_ctrl_new_std(&sensor->ctrl_handler,
                                           &milianke_ctrl_ops,
                                           V4L2_CID_PIXEL_RATE,
                                           0, DUMMY_PIXEL_RATE, 1,
                                           DUMMY_PIXEL_RATE);
    if (sensor->pixel_rate)
        sensor->pixel_rate->flags |= V4L2_CTRL_FLAG_READ_ONLY;
    sensor->vblank = v4l2_ctrl_new_std(&sensor->ctrl_handler, NULL,
                                       V4L2_CID_VBLANK, 45, 45, 1, 45);
    if (sensor->ctrl_handler.error)
    {
        ret = sensor->ctrl_handler.error;
        goto err_ctrl;
    }

    sensor->mipi_en_gpio = devm_gpiod_get_optional(&client->dev, "mipi-en",
                                                   GPIOD_OUT_LOW);
    if (IS_ERR(sensor->mipi_en_gpio))
    {
        ret = PTR_ERR(sensor->mipi_en_gpio);
        goto err_ctrl;
    }

    if (sensor->mipi_en_gpio)
        gpiod_set_value_cansleep(sensor->mipi_en_gpio, 0);
    if (sensor->mipi_en_gpio && always_on)
    {
        dev_info(&client->dev,
                 "always_on=1 ignored: mipi-en toggled by s_stream()\n");
    }

    sd->ctrl_handler = &sensor->ctrl_handler;
    v4l2_ctrl_handler_setup(&sensor->ctrl_handler);

    {
        struct fwnode_handle *ep;

        ep = fwnode_graph_get_next_endpoint(dev_fwnode(&client->dev),
                                            NULL);
        if (ep)
            sd->fwnode = ep;
    }

    ret = v4l2_async_register_subdev(sd);
    if (ret)
        goto err_ctrl;

    dev_info(&client->dev,
             "milianke MIPI sensor registered: %s (FPGA CSI-2, %ux%u@%ufps, link-freq=%lld, mipi-en=%s)\n",
             sd->name, DUMMY_WIDTH, DUMMY_HEIGHT, DUMMY_FPS_DEN,
             (long long)DUMMY_LINK_FREQ,
             sensor->mipi_en_gpio ? "yes" : "none");

    return 0;

err_ctrl:
    v4l2_ctrl_handler_free(&sensor->ctrl_handler);
    media_entity_cleanup(&sd->entity);
err_mutex:
    mutex_destroy(&sensor->mutex);
    return ret;
}

static void milianke_remove(struct i2c_client *client)
{
    struct v4l2_subdev *sd = i2c_get_clientdata(client);
    struct milianke_mipi *sensor =
        container_of(sd, struct milianke_mipi, subdev);

    v4l2_async_unregister_subdev(sd);
    media_entity_cleanup(&sd->entity);
    v4l2_ctrl_handler_free(&sensor->ctrl_handler);
    mutex_destroy(&sensor->mutex);
}

static const struct of_device_id milianke_of_match[] = {

    {.compatible = "milianke,fpga-virtual"},
    {},
};
MODULE_DEVICE_TABLE(of, milianke_of_match);

static const struct i2c_device_id milianke_id[] = {
    {"milianke_mipi", 0},
    {},
};
MODULE_DEVICE_TABLE(i2c, milianke_id);

static struct i2c_driver milianke_driver = {
    .driver = {
        .name = "milianke_mipi",
        .of_match_table = milianke_of_match,
    },
    .probe = milianke_probe,
    .remove = milianke_remove,
    .id_table = milianke_id,
};
module_i2c_driver(milianke_driver);

MODULE_DESCRIPTION("Milianke virtual MIPI CSI-2 sensor (RK3576)");
MODULE_AUTHOR("Milianke / AFC03 FPGA team");
MODULE_LICENSE("GPL");
