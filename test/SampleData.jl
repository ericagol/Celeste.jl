module SampleData

using Celeste: Model, DeterministicVI
import Celeste: Infer

import ..Synthetic

using Distributions
using StaticArrays
import WCS, FITSIO, DataFrames

export empty_model_params, dat_dir,
       sample_ce, perturb_params,
       sample_star_fluxes, sample_galaxy_fluxes,
       gen_sample_star_dataset, gen_sample_galaxy_dataset,
       gen_two_body_dataset, gen_three_body_dataset, gen_n_body_dataset,
       make_elbo_args, true_star_init

const dat_dir = joinpath(Pkg.dir("Celeste"), "test", "data")

const sample_star_fluxes = [
    4.451805E+03,1.491065E+03,2.264545E+03,2.027004E+03,1.846822E+04]
const sample_galaxy_fluxes = [
    1.377666E+01, 5.635334E+01, 1.258656E+02,
    1.884264E+02, 2.351820E+02] * 100  # 1x wasn't bright enough

# A world coordinate system where the world and pixel coordinates are the same.
const wcs_id = WCS.WCSTransform(2,
                    cd = Float64[1 0; 0 1],
                    ctype = ["none", "none"],
                    crpix = Float64[1, 1],
                    crval = Float64[1, 1]);


"""
Turn a images and vector of catalog entries into elbo arguments
that can be used with Celeste.
"""
function make_elbo_args(images::Vector{Image},
                        catalog::Vector{CatalogEntry};
                        active_source=-1,
                        patch_radius_pix::Float64=NaN,
                        include_kl=true)
    patches = Infer.get_sky_patches(images,
                                    catalog,
                                    radius_override_pix=patch_radius_pix)
    S = length(catalog)
    active_sources = active_source > 0 ? [active_source] :
                                          S <= 3 ? collect(1:S) : [1,2,3]
    ElboArgs(images, patches, active_sources; include_kl=include_kl)
end


"""
Load a stamp into a Celeste images.
"""
function load_stamp_blob(stamp_dir, stamp_id)
    function fetch_image(b)
        band_letter = band_letters[b]
        filename = "$stamp_dir/stamp-$band_letter-$stamp_id.fits"

        fits = FITSIO.FITS(filename)
        hdr = FITSIO.read_header(fits[1])
        original_pixels = read(fits[1])
        dn = original_pixels / hdr["CALIB"] + hdr["SKY"]
        nelec_f32 = round.(dn * hdr["GAIN"])
        nelec = convert(Array{Float64}, nelec_f32)

        header_str = FITSIO.read_header(fits[1], String)
        wcs = WCS.from_header(header_str)[1]
        close(fits)

        alphaBar = [hdr["PSF_P0"]; hdr["PSF_P1"]; hdr["PSF_P2"]]
        xiBar = [
            [hdr["PSF_P3"]  hdr["PSF_P4"]];
            [hdr["PSF_P5"]  hdr["PSF_P6"]];
            [hdr["PSF_P7"]  hdr["PSF_P8"]]]'

        tauBar = Array{Float64,3}(2, 2, 3)
        tauBar[:,:,1] = [[hdr["PSF_P9"] hdr["PSF_P11"]];
                         [hdr["PSF_P11"] hdr["PSF_P10"]]]
        tauBar[:,:,2] = [[hdr["PSF_P12"] hdr["PSF_P14"]];
                         [hdr["PSF_P14"] hdr["PSF_P13"]]]
        tauBar[:,:,3] = [[hdr["PSF_P15"] hdr["PSF_P17"]];
                         [hdr["PSF_P17"] hdr["PSF_P16"]]]

        psf = [PsfComponent(alphaBar[k], SVector{2,Float64}(xiBar[:, k]),
                            SMatrix{2,2,Float64,4}(tauBar[:, :, k])) for k in 1:3]

        H, W = size(original_pixels)
        iota = hdr["GAIN"] / hdr["CALIB"]
        epsilon = hdr["SKY"] * hdr["CALIB"]

        run_num = round(Int, hdr["RUN"])
        camcol_num = round(Int, hdr["CAMCOL"])
        field_num = round(Int, hdr["FIELD"])

        sky = SkyIntensity(fill(epsilon, H, W),
                           collect(1:H), collect(1:W), ones(H))
        iota_vec = fill(iota, H)
        empty_psf_comp = RawPSF(Matrix{Float64}(0, 0), 0, 0,
                                 Array{Float64,3}(0, 0, 0))

        Image(H, W, nelec, b, wcs, psf,
              run_num, camcol_num, field_num, sky, iota_vec,
              empty_psf_comp)
    end

    images = map(fetch_image, 1:5)
end


function load_stamp_catalog_df(cat_dir, stamp_id, images; match_blob=false)
    # These files are generated by
    # https://github.com/dstndstn/tractor/blob/master/projects/inference/testblob2.py
    cat_fits = FITSIO.FITS("$cat_dir/cat-$stamp_id.fits")
    num_cols = FITSIO.read_key(cat_fits[2], "TFIELDS")[1]
    ttypes = [FITSIO.read_key(cat_fits[2], "TTYPE$i")[1] for i in 1:num_cols]

    df = DataFrames.DataFrame()
    for i in 1:num_cols
        tmp_data = read(cat_fits[2], ttypes[i])
        df[Symbol(ttypes[i])] = tmp_data
    end

    close(cat_fits)

    if match_blob
        camcol_matches = df[:camcol] .== images[3].camcol_num
        run_matches = df[:run] .== images[3].run_num
        field_matches = df[:field] .== images[3].field_num
        df = df[camcol_matches & run_matches & field_matches, :]
    end

    df
end


"""
Load a stamp catalog.
"""
function load_stamp_catalog(cat_dir, stamp_id, images; match_blob=false)
    df = load_stamp_catalog_df(cat_dir, stamp_id, images,
                                    match_blob=match_blob)
    df[:objid] = [ string(s) for s=1:size(df)[1] ]

    function row_to_ce(row)
        x_y = [row[1, :ra], row[1, :dec]]
        star_fluxes = zeros(5)
        gal_fluxes = zeros(5)
        fracs_dev = [row[1, :frac_dev], 1 - row[1, :frac_dev]]
        for b in 1:length(band_letters)
            bl = band_letters[b]
            psf_col = Symbol("psfflux_$bl")

            # TODO: How can there be negative fluxes?
            star_fluxes[b] = max(row[1, psf_col], 1e-6)

            dev_col = Symbol("devflux_$bl")
            exp_col = Symbol("expflux_$bl")
            gal_fluxes[b] += fracs_dev[1] * max(row[1, dev_col], 1e-6) +
                             fracs_dev[2] * max(row[1, exp_col], 1e-6)
        end

        fits_ab = fracs_dev[1] > .5 ? row[1, :ab_dev] : row[1, :ab_exp]
        fits_phi = fracs_dev[1] > .5 ? row[1, :phi_dev] : row[1, :phi_exp]
        fits_theta = fracs_dev[1] > .5 ? row[1, :theta_dev] : row[1,
:theta_exp]

        # tractor defines phi as -1 * the phi catalog for some reason.
        if !match_blob
            fits_phi *= -1.
        end

        re_arcsec = max(fits_theta, 1. / 30)  # re = effective radius
        re_pixel = re_arcsec / 0.396

        phi90 = 90 - fits_phi
        phi90 -= floor(phi90 / 180) * 180
        phi90 *= (pi / 180)

        CatalogEntry(x_y, row[1, :is_star], star_fluxes,
            gal_fluxes, row[1, :frac_dev], fits_ab, phi90, re_pixel,
            row[1, :objid], 0)
    end

    CatalogEntry[row_to_ce(df[i, :]) for i in 1:size(df, 1)]
end


function empty_model_params(S::Int)
    vp = [DeterministicVI.generic_init_source([ 0., 0. ]) for s in 1:S]
    ElboArgs(Image[],
             vp,
             Matrix{SkyPatch}(S, 0),
             collect(1:S))
end


function sample_ce(pos, is_star::Bool)
    CatalogEntry(pos, is_star, sample_star_fluxes, sample_galaxy_fluxes,
        0.1, .7, pi/4, 4., "sample", 0)
end


# for testing away from the truth, where derivatives != 0
function perturb_params(vp)
    for vs in vp
        vs[ids.a] = [ 0.4, 0.6 ]
        vs[ids.u[1]] += .8
        vs[ids.u[2]] -= .7
        vs[ids.r1] -= log(10)
        vs[ids.r2] *= 25.
        vs[ids.e_dev] += 0.05
        vs[ids.e_axis] += 0.05
        vs[ids.e_angle] += pi/10
        vs[ids.e_scale] *= 1.2
        vs[ids.c1] += 0.5
        vs[ids.c2] =  1e-1
    end
end


function gen_sample_star_dataset(; perturb=true)
    srand(1)
    images0 = load_stamp_blob(dat_dir, "164.4311-39.0359_2kpsf")
    for b in 1:5
        images0[b].H, images0[b].W = 20, 23
        images0[b].wcs = wcs_id
    end
    catalog = [sample_ce([10.1, 12.2], true),]
    images = Synthetic.gen_blob(images0, catalog)
    ea = make_elbo_args(images, catalog)

    vp = Vector{Float64}[DeterministicVI.catalog_init_source(ce) for ce in catalog]
    if perturb
        perturb_params(vp)
    end

    ea, vp, catalog
end


function gen_sample_galaxy_dataset(; perturb=true, include_kl=true)
    srand(1)
    images0 = load_stamp_blob(dat_dir, "164.4311-39.0359_2kpsf")
    for b in 1:5
        images0[b].H, images0[b].W = 20, 23
        images0[b].wcs = wcs_id
    end
    catalog = [sample_ce([8.5, 9.6], false),]
    images = Synthetic.gen_blob(images0, catalog)
    ea = make_elbo_args(images, catalog; include_kl=include_kl)

    vp = Vector{Float64}[DeterministicVI.catalog_init_source(ce) for ce in catalog]
    if perturb
        perturb_params(vp)
    end

    ea, vp, catalog
end

function gen_two_body_dataset(; perturb=true)
    # A small two-body dataset for quick unit testing.  These objects
    # will be too close to be identifiable.

    srand(1)
    images0 = load_stamp_blob(dat_dir, "164.4311-39.0359_2kpsf")
    for b in 1:5
        images0[b].H, images0[b].W = 20, 23
        images0[b].wcs = wcs_id
    end
    catalog = [
        sample_ce([4.5, 3.6], false),
        sample_ce([10.1, 12.1], true)
    ]
    images = Synthetic.gen_blob(images0, catalog)
    ea = make_elbo_args(images, catalog)

    vp = Vector{Float64}[DeterministicVI.catalog_init_source(ce) for ce in catalog]
    if perturb
        perturb_params(vp)
    end

    ea, vp, catalog
end



function gen_three_body_dataset(; perturb=true)
    srand(1)
    images0 = load_stamp_blob(dat_dir, "164.4311-39.0359_2kpsf")
    for b in 1:5
        images0[b].H, images0[b].W = 112, 238
        images0[b].wcs = wcs_id
    end
    catalog = [
        sample_ce([4.5, 3.6], false),
        sample_ce([60.1, 82.2], true),
        sample_ce([71.3, 100.4], false),
    ];
    images = Synthetic.gen_blob(images0, catalog);
    ea = make_elbo_args(images, catalog);

    vp = Vector{Float64}[DeterministicVI.catalog_init_source(ce) for ce in catalog]
    if perturb
        perturb_params(vp)
    end

    ea, vp, catalog
end


"""
Generate a large dataset with S randomly placed bodies and non-constant
background.
"""
function gen_n_body_dataset(
        S::Int; patch_pixel_radius=20., seed=NaN, perturb=true)
    if !isnan(seed)
        srand(seed)
    end

    images0 = load_stamp_blob(dat_dir, "164.4311-39.0359_2kpsf");
    img_size_h = 900
    img_size_w = 1000
    for b in 1:5
        images0[b].H, images0[b].W = img_size_h, img_size_w
    end

    fluxes = [4.451805E+03,1.491065E+03,2.264545E+03,2.027004E+03,1.846822E+04]

    locations = rand(2, S) .* [img_size_h, img_size_w]
    world_locations = WCS.pix_to_world(images0[3].wcs, locations)

    catalog = CatalogEntry[CatalogEntry(world_locations[:, s], true,
            fluxes, fluxes, 0.1, .7, pi/4, 4., string(s), s) for s in 1:S];

    images = Synthetic.gen_blob(images0, catalog);

    # Make non-constant background.
    for b=1:5
        images[b].iota_vec = fill(images[b].iota_vec[1], images[b].H)
        images[b].sky = SkyIntensity(fill(images[b].sky[1,1], images[b].H, images[b].W),
                                     collect(1:images[b].H), collect(1:images[b].W),
                                     ones(images[b].H))
    end

    ea = make_elbo_args(
        images, catalog, patch_radius_pix=patch_pixel_radius)

    vp = Vector{Float64}[DeterministicVI.catalog_init_source(ce) for ce in catalog]
    if perturb
        perturb_params(vp)
    end

    ea, vp, catalog
end


function true_star_init()
    ea, vp, catalog = gen_sample_star_dataset(perturb=false)

    vp[1][ids.a] = [ 1.0 - 1e-4, 1e-4 ]
    vp[1][ids.r2] = 1e-4
    vp[1][ids.r1] = log(sample_star_fluxes[3]) - 0.5 * vp[1][ids.r2]
    vp[1][ids.c2] = 1e-4

    ea, vp, catalog
end


end # End module
