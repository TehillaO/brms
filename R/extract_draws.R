extract_draws <- function(x, ...) {
  # extract data and posterior draws
  UseMethod("extract_draws")
}

#' @export
extract_draws.default <- function(x, ...) {
  NULL
}

#' @export
extract_draws.brmsfit <- function(x, newdata = NULL, re_formula = NULL, 
                                  sample_new_levels = "uncertainty",
                                  incl_autocor = TRUE, resp = NULL,
                                  subset = NULL, nsamples = NULL, nug = NULL, 
                                  smooths_only = FALSE, ...) {
  # extract all data and posterior draws required in (non)linear_predictor
  # Args:
  #   see doc of logLik.brmsfit
  #   ...: passed to validate_newdata
  # Returns:
  #   A named list to be interpreted by linear_predictor
  snl_options <- c("uncertainty", "gaussian", "old_levels")
  sample_new_levels <- match.arg(sample_new_levels, snl_options)
  x <- restructure(x)
  if (!incl_autocor) {
    x <- remove_autocor(x) 
  }
  subset <- subset_samples(x, subset, nsamples)
  samples <- as.matrix(x, subset = subset)
  # prepare (new) data and stan data 
  new <- !is.null(newdata)
  newd_args <- nlist(newdata, object = x, re_formula, resp, ...)
  newdata <- do.call(validate_newdata, newd_args)
  newd_args$newdata <- newdata
  newd_args$internal <- TRUE
  sdata <- do.call(standata, newd_args)
  new_formula <- update_re_terms(x$formula, re_formula)
  bterms <- parse_bf(new_formula)
  ranef <- tidy_ranef(bterms, x$data)
  meef <- tidy_meef(bterms, x$data)
  args <- nlist(
    x = bterms, samples, sdata, data = x$data,
    ranef, old_ranef = x$ranef, meef, resp,
    sample_new_levels, nug, smooths_only, new,
    stanvars = names(x$stanvars)
  )
  if (new) {
    # extract_draws_re() also requires the new level names
    # original level names are already passed via old_ranef
    new_levels <- attr(tidy_ranef(bterms, newdata), "levels")
    attr(args$ranef, "levels") <- new_levels
    if (length(get_effect(bterms, "gp"))) {
      # GPs for new data require the original data as well
      args$old_sdata <- standata(x, internal = TRUE, ...)
    }
  }
  do.call(extract_draws, args)
}

extract_draws.mvbrmsterms <- function(x, samples, sdata, resp = NULL, ...) {
  resp <- validate_resp(resp, x$responses)
  if (length(resp) > 1) {
    draws <- list(nsamples = nrow(samples), nobs = sdata$N)
    draws$resps <- named_list(resp)
    draws$old_order <- attr(sdata, "old_order")
    for (r in resp) {
      draws$resps[[r]] <- extract_draws(
        x$terms[[r]], samples = samples, sdata = sdata, ...
      )
    }
    if (x$rescor) {
      draws$f <- draws$resps[[1]]$f
      draws$f$fun <- paste0(draws$f$family, "_mv")
      rescor <- get_cornames(resp, type = "rescor", brackets = FALSE)
      draws$mvpars$rescor <- get_samples(samples, rescor, exact = TRUE)
      if (draws$f$family == "student") {
        # store in draws$dpars so that get_dpar can be called on nu
        draws$dpars$nu <- as.vector(get_samples(samples, "^nu$"))
      }
      draws$data$N <- draws$resps[[1]]$data$N
      draws$data$weights <- draws$resps[[1]]$data$weights
      Y <- lapply(draws$resps, function(x) x$data$Y)
      draws$data$Y <- do.call(cbind, Y)
    }
    draws <- structure(draws, class = "mvbrmsdraws")
  } else {
    draws <- extract_draws(
      x$terms[[resp]], samples = samples, sdata = sdata, ...
    )
  }
  draws
}

#' @export
extract_draws.brmsterms <- function(x, samples, sdata, ...) {
  nsamples <- nrow(samples)
  nobs <- sdata$N
  resp <- usc(combine_prefix(x))
  draws <- nlist(f = prepare_family(x), nsamples, nobs, resp = x$resp)
  draws$old_order <- attr(sdata, "old_order")
  valid_dpars <- valid_dpars(x)
  draws$dpars <- named_list(valid_dpars)
  for (dp in valid_dpars) {
    dp_regex <- paste0("^", dp, resp, "$")
    if (is.btl(x$dpars[[dp]]) || is.btnl(x$dpars[[dp]])) {
      draws$dpars[[dp]] <- extract_draws(
        x$dpars[[dp]], samples = samples, sdata = sdata, ...
      )
    } else if (is.numeric(x$fdpars[[dp]]$value)) {
      draws$dpars[[dp]] <- x$fdpars[[dp]]$value
    } else if (any(grepl(dp_regex, colnames(samples)))) {
      draws$dpars[[dp]] <- as.vector(get_samples(samples, dp_regex))
    }
  }
  if (is.mixfamily(x$family)) {
    families <- family_names(x$family)
    thetas <- paste0("theta", seq_along(families))
    if (any(ulapply(draws$dpars[thetas], is.list))) {
      # theta was predicted
      missing_id <- which(ulapply(draws$dpars[thetas], is.null))
      draws$dpars[[paste0("theta", missing_id)]] <- structure(
        as_draws_matrix(0, c(nsamples, nobs)), predicted = TRUE
      )
    } else {
      # theta was not predicted
      draws$dpars$theta <- do.call(cbind, draws$dpars[thetas])
      draws$dpars[thetas] <- NULL
      if (nrow(draws$dpars$theta) == 1L) {
        dim <- c(nrow(samples), ncol(draws$dpars$theta))
        draws$dpars$theta <- as_draws_matrix(draws$dpars$theta, dim = dim)
      }
    }
  }
  if (use_cov(x$autocor) || is.cor_sar(x$autocor)) {
    # only include autocor samples on the top-level of draws 
    # when using the covariance formulation of ARMA / SAR structures
    draws$ac <- extract_draws_autocor(x, samples, sdata, ...)
  }
  draws$data <- extract_draws_data(x, sdata = sdata, ...)
  structure(draws, class = "brmsdraws")
}

#' @export
extract_draws.btnl <- function(x, samples, sdata, ...) {
  draws <- list(
    f = x$family, nlform = x$formula[[2]],
    nsamples = nrow(samples), nobs = sdata$N
  )
  class(draws) <- "bdrawsnl"
  if (is_nlpar(x)) {
    draws$nlpar <- x$nlpar
    return(draws)
  }
  nlpars <- names(x$nlpars)
  for (nlp in nlpars) {
    draws$nlpars[[nlp]] <- extract_draws(
      x$nlpars[[nlp]], samples = samples, sdata = sdata, ...
    )
  }
  p <- usc(combine_prefix(x))
  C <- sdata[[paste0("C", p)]]
  stopifnot(is.matrix(C))
  for (cov in colnames(C)) {
    draws$C[[cov]] <- as_draws_matrix(
      C[, cov], dim = c(nrow(samples), nrow(C))
    )
  }
  draws
}

#' @export
extract_draws.btl <- function(x, samples, sdata, smooths_only = FALSE, ...) {
  nsamples <- nrow(samples)
  draws <- nlist(f = x$family, nsamples, nobs = sdata$N)
  class(draws) <- "bdrawsl"
  args <- nlist(bterms = x, samples, sdata, ...)
  draws$fe <- do.call(extract_draws_fe, args)
  draws$sm <- do.call(extract_draws_sm, args)
  if (smooths_only) {
    # make sure only smooth terms will be included in draws
    return(draws)
  }
  draws$sp <- do.call(extract_draws_sp, args)
  draws$cs <- do.call(extract_draws_cs, args)
  draws$gp <- do.call(extract_draws_gp, args)
  draws$re <- do.call(extract_draws_re, args)
  draws$offset <- do.call(extract_draws_offset, args)
  if (!(use_cov(x$autocor) || is.cor_sar(x$autocor))) {
    draws$ac <- do.call(extract_draws_autocor, args)
  }
  draws
}

extract_draws_fe <- function(bterms, samples, sdata, ...) {
  # extract draws of ordinary population-level effects
  draws <- list()
  p <- usc(combine_prefix(bterms))
  X <- sdata[[paste0("X", p)]]
  fixef <- colnames(X)
  if (length(fixef)) {
    draws$X <- X
    b_pars <- paste0("b", p, "_", fixef)
    draws$b <- get_samples(samples, b_pars, exact = TRUE)
  }
  draws
}

extract_draws_sp <- function(bterms, samples, sdata, data, 
                             meef, new = FALSE, ...) {
  # extract draws of special effects terms
  draws <- list()
  spef <- tidy_spef(bterms, data)
  if (!nrow(spef)) return(draws)
  p <- usc(combine_prefix(bterms))
  # prepare calls evaluated in sp_predictor
  draws$calls <- vector("list", nrow(spef))
  for (i in seq_along(draws$calls)) {
    call <- spef$call_prod[[i]]
    if (!is.null(spef$call_mo[[i]])) {
      new_mo <- paste0(
        ".mo(simo_", spef$Imo[[i]], ", Xmo_", spef$Imo[[i]], ")"
      )
      call <- rename(call, spef$call_mo[[i]], new_mo)
    }
    if (!is.null(spef$call_me[[i]])) {
      new_me <- paste0("Xme_", seq_along(meef$term))
      call <- rename(call, meef$term, new_me)
    }
    if (!is.null(spef$call_mi[[i]])) {
      new_mi <- paste0("Yl_", spef$vars_mi[[i]])
      call <- rename(call, spef$call_mi[[i]], new_mi)
    }
    if (spef$Ic[i] > 0) {
      str_add(call) <- paste0(" * Csp_", spef$Ic[i])
    }
    draws$calls[[i]] <- parse(text = paste0(call))
  }
  # extract general data and parameters for special effects
  bsp_pars <- paste0("bsp", p, "_", spef$coef)
  draws$bsp <- get_samples(samples, bsp_pars, exact = TRUE)
  # prepare draws specific to monotonic effects
  simo_coef <- get_simo_labels(spef)
  draws$simo <- draws$Xmo <- named_list(simo_coef)
  for (i in seq_along(simo_coef)) {
    J <- seq_len(sdata$Jmo[i])
    simo_par <- paste0("simo", p, "_", simo_coef[i], "[", J, "]")
    draws$simo[[i]] <- get_samples(samples, simo_par, exact = TRUE)
    draws$Xmo[[i]] <- sdata[[paste0("Xmo", p, "_", i)]]
  }
  # prepare draws specific to noise-free effects
  warn_me <- FALSE
  if (nrow(meef)) {
    save_mevars <- any(grepl("^Xme_", colnames(samples)))
    warn_me <- warn_me || !new && !save_mevars
    draws$Xme <- named_list(meef$coef)
    Xme_pars <- paste0("Xme_", escape_all(meef$coef), "\\[")
    Xn <- sdata[paste0("Xn_", seq_len(nrow(meef)))]
    noise <- sdata[paste0("noise_", seq_len(nrow(meef)))]
    groups <- unique(meef$grname)
    for (i in seq_along(groups)) {
      g <- groups[i]
      K <- which(meef$grname %in% g)
      if (nzchar(g)) {
        Jme <- sdata[[paste0("Jme_", i)]]
        me_dim <- c(nrow(draws$bsp), length(unique(Jme)))
      } else {
        me_dim <- c(nrow(draws$bsp), sdata$N)
      }
      if (!new && save_mevars) {
        # extract original samples of latent variables
        for (k in K) {
          draws$Xme[[k]] <- get_samples(samples, Xme_pars[k])
        }
      } else {
        # sample new values of latent variables
        for (k in K) {
          dXn <- as_draws_matrix(Xn[[k]], me_dim)
          dnoise <- as_draws_matrix(noise[[k]], me_dim)
          draws$Xme[[k]] <- array(rnorm(prod(me_dim), dXn, dnoise), me_dim)
          remove(dXn, dnoise)
        }
      }
      if (nzchar(g)) {
        for (k in K) {
          draws$Xme[[k]] <- draws$Xme[[k]][, Jme]
        }
      }
    }
  }
  # prepare draws specific to missing value variables
  dim <- c(nrow(draws$bsp), sdata$N)
  vars_mi <- unique(unlist(spef$vars_mi))
  if (length(vars_mi)) {
    resps <- usc(vars_mi)
    Yl_names <- paste0("Yl", resps)
    draws$Yl <- named_list(Yl_names)
    for (i in seq_along(draws$Yl)) {
      Y <- as_draws_matrix(sdata[[paste0("Y", resps[i])]], dim)
      sdy <- sdata[[paste0("noise", resps[i])]]
      if (is.null(sdy)) {
        # missings only
        draws$Yl[[i]] <- Y
        if (!new) {
          Ymi_pars <- paste0("Ymi", resps[i], "\\[")
          Ymi <- get_samples(samples, Ymi_pars)
          Jmi <- sdata[[paste0("Jmi", resps[i])]]
          draws$Yl[[i]][, Jmi] <- Ymi
        }
      } else {
        # measurement-error in the response
        save_mevars <- any(grepl("^Yl_", colnames(samples)))
        if (save_mevars && !new) {
          Yl_pars <- paste0("Yl", resps[i], "\\[")
          draws$Yl[[i]] <- get_samples(samples, Yl_pars)
        } else {
          warn_me <- warn_me || !new
          sdy <- as_draws_matrix(sdy, dim)
          draws$Yl[[i]] <- array(rnorm(prod(dim), Y, sdy), dim)
        }
      }
    }
  }
  if (warn_me) {
    warning2(
      "Noise-free variables were not saved. Please set ",
      "argument 'save_mevars' to TRUE when fitting your model. ",
      "Treating original data as if it was new data as a workaround."
    )
  }
  # prepare covariates
  ncovars <- max(spef$Ic)
  for (i in seq_len(ncovars)) {
    draws$Csp[[i]] <- sdata[[paste0("Csp", p, "_", i)]]
    draws$Csp[[i]] <- as_draws_matrix(draws$Csp[[i]], dim = dim)
  }
  draws
}

extract_draws_cs <- function(bterms, samples, sdata, data, ...) {
  # extract draws of category specific effects
  draws <- list()
  p <- usc(combine_prefix(bterms))
  resp <- usc(bterms$resp)
  int_regex <- paste0("^b", p, "_Intercept\\[")
  is_ordinal <- any(grepl(int_regex, colnames(samples))) 
  if (is_ordinal) {
    draws$ncat <- sdata[[paste0("ncat", resp)]]
    draws$Intercept <- get_samples(samples, int_regex)
    csef <- colnames(get_model_matrix(bterms$cs, data))
    if (length(csef)) {
      cs_pars <- paste0("^bcs", p, "_", csef, "\\[")
      draws$bcs <- get_samples(samples, cs_pars)
      draws$Xcs <- sdata[[paste0("Xcs", p)]]
    }
  }
  draws
}

extract_draws_sm <- function(bterms, samples, sdata, data, ...) {
  # extract draws of smooth terms
  smef <- tidy_smef(bterms, data)
  p <- usc(combine_prefix(bterms))
  draws <- named_list(smef$label)
  for (i in seq_along(draws)) {
    sm <- list()
    for (j in seq_len(smef$nbases[i])) {
      sm$Zs[[j]] <- sdata[[paste0("Zs", p, "_", i, "_", j)]]
      spars <- paste0("^s", p, "_", smef$label[i], "_", j, "\\[")
      sm$s[[j]] <- get_samples(samples, spars)
    }
    draws[[i]] <- sm
  }
  draws
}

extract_draws_gp <- function(bterms, samples, sdata, data,
                             new = FALSE, nug = NULL,
                             old_sdata = NULL, ...) {
  # extract draws for Gaussian processes
  # Args:
  #   new: Is new data used?
  #   nug: small numeric value to avoid numerical problems in GPs
  #   old_sdata: standata object based on the original data
  gpef <- tidy_gpef(bterms, data)
  if (!nrow(gpef)) {
    return(list())
  }
  if (new) {
    stopifnot(!is.null(old_sdata))
  }
  p <- usc(combine_prefix(bterms))
  if (is.null(nug)) {
    nug <- ifelse(new, 1e-8, 1e-11)
  }
  draws <- named_list(gpef$label)
  for (i in seq_along(draws)) {
    lvls <- gpef$bylevels[[i]]
    if (length(lvls)) {
      gp <- named_list(lvls)
      for (j in seq_along(lvls)) {
        gp[[lvls[j]]] <- .extract_draws_gp(
          gpef, samples = samples, sdata = sdata,
          old_sdata = old_sdata, nug = nug, new = new,
          byj = j, p = p, i = i
        )
      }
      attr(gp, "byfac") <- TRUE
    } else {
      gp <- .extract_draws_gp(
        gpef, samples = samples, sdata = sdata,
        old_sdata = old_sdata, nug = nug, new = new, 
        p = p, i = i
      )
    }
    draws[[i]] <- gp
  }
  draws
}

.extract_draws_gp <- function(gpef, samples, sdata, old_sdata,
                              nug, new, p, i, byj = NULL) {
  # extract draws for Gaussian processes
  # Args:
  #   gpef: output of tidy_gpef
  #   p: prefix created by combine_prefix()
  #   i: indiex of the Gaussian process
  #   byj: index for the level of a categorical 'by' vaiable
  # Return:
  #   a list to be evaluated by .predictor_gp()
  if (is.null(byj)) {
    lvl <- ""
  } else {
    lvl <- gpef$bylevels[[i]][byj]
  }
  j <- usc(byj)
  gp <- list()
  gp_name <- escape_all(paste0(gpef$label[i], lvl))
  sdgp <- paste0("^sdgp", p, "_", gp_name, "$")
  gp$sdgp <- as.numeric(get_samples(samples, sdgp))
  lscale <- paste0("^lscale", p, "_", gp_name, "$")
  gp$lscale <- as.numeric(get_samples(samples, lscale))
  zgp_regex <- paste0("^zgp", p, "_", gp_name, "\\[")
  gp$zgp <- get_samples(samples, zgp_regex)
  Xgp_name <- paste0("Xgp", p, "_", i, j)
  Igp_name <- paste0("Igp", p, "_", i, j)
  Jgp_name <- paste0("Jgp", p, "_", i, j)
  if (new) {
    gp$x <- old_sdata[[Xgp_name]]
    gp$nug <- 1e-11
    # computing GPs for new data requires the old GP terms
    gp$yL <- .predictor_gp(gp)
    gp$x_new <- sdata[[Xgp_name]]
    gp$Igp <- sdata[[Igp_name]]
  } else {
    gp$x <- sdata[[Xgp_name]]
    gp$Igp <- sdata[[Igp_name]]
  }
  gp$Jgp <- sdata[[Jgp_name]]
  if (is.null(byj)) {
    # possible continuous 'by' variable
    gp$bynum <- sdata[[paste0("Cgp", p, "_", i)]]
  }
  gp$nug <- nug
  gp
}

extract_draws_re <- function(bterms, samples, sdata, data, ranef, old_ranef, 
                             sample_new_levels = "uncertainty", ...) {
  # extract draws of group-level effects
  # Args:,
  #   ranef: output of tidy_ranef based on the new formula and old data
  #   old_ranef: same as 'ranef' but based on the original formula
  draws <- list()
  px <- check_prefix(bterms)
  ranef <- subset2(ranef, ls = px)
  if (!nrow(ranef)) {
    return(draws)
  }
  p <- combine_prefix(px)
  groups <- unique(ranef$group)
  old_ranef <- subset2(old_ranef, ls = px)
  # assigning S4 objects requires initialisation of list elements
  draws[c("Z", "Zsp", "Zcs")] <- list(named_list(groups))
  for (g in groups) {
    # prepare general variables related to group g
    sub_ranef <- subset2(ranef, group = g)
    sub_old_ranef <- subset2(old_ranef, group = g)
    new_levels <- attr(ranef, "levels")[[g]]
    old_levels <- attr(old_ranef, "levels")[[g]]
    new_by_per_level <- attr(new_levels, "by")
    old_by_per_level <- attr(old_levels, "by")
    really_new_levels <- setdiff(new_levels, old_levels)
    nlevels <- length(old_levels) 
    nranef <- nrow(sub_ranef)
    # prepare samples of group-level effects
    rpars <- paste0("^r_", g, usc(usc(p)), "\\[")
    rsamples <- get_samples(samples, rpars)
    if (is.null(rsamples)) {
      stop2(
        "Group-level effects for each level of group ", 
        "'", g, "' not found. Please set 'save_ranef' to ", 
        "TRUE when fitting your model."
      )
    }
    new_rpars <- match(sub_ranef$coef, sub_old_ranef$coef)
    new_rpars <- outer(seq_len(nlevels), (new_rpars - 1) * nlevels, "+")
    new_rpars <- as.vector(new_rpars)
    rsamples <- rsamples[, new_rpars, drop = FALSE]
    # prepare data required for indexing parameters
    gtype <- sub_ranef$gtype[1]
    id <- sub_ranef$id[1]
    if (gtype == "mm") {
      ngf <- length(sub_ranef$gcall[[1]]$groups)
      gf <- sdata[paste0("J_", id, "_", seq_len(ngf))]
      weights <- sdata[paste0("W_", id, "_", seq_len(ngf))]
    } else {
      gf <- sdata[paste0("J_", id)]
      weights <- list(rep(1, length(gf[[1]])))
    }
    # incorporate new gf levels
    new_rsamples <- vector("list", length(gf))
    max_level <- nlevels
    for (i in seq_along(gf)) {
      has_new_levels <- any(gf[[i]] > nlevels)
      if (has_new_levels) {
        if (sample_new_levels %in% c("old_levels", "gaussian")) {
          new_indices <- sort(setdiff(gf[[i]], seq_len(nlevels)))
          new_rsamples[[i]] <- matrix(
            nrow = nrow(rsamples), ncol = nranef * length(new_indices)
          )
          if (sample_new_levels == "old_levels") {
            for (j in seq_along(new_indices)) {
              # choose a person to take the group-level effects from
              if (length(old_by_per_level)) {
                new_by <- new_by_per_level[new_levels == really_new_levels[j]]
                possible_levels <- old_levels[old_by_per_level == new_by]
                possible_levels <- which(old_levels %in% possible_levels)
                take_level <- sample(possible_levels, 1)
              } else {
                take_level <- sample(seq_len(nlevels), 1)
              }
              for (k in seq_len(nranef)) {
                take <- (k - 1) * nlevels + take_level
                new_rsamples[[i]][, (j - 1) * nranef + k] <- rsamples[, take]
              }
            }
          } else if (sample_new_levels == "gaussian") {
            if (any(!sub_ranef$dist %in% "gaussian")) {
              stop2("Option sample_new_levels = 'gaussian' is not ",
                    "available for non-gaussian group-level effects.")
            }
            for (j in seq_along(new_indices)) {
              # extract hyperparameters used to compute the covariance matrix
              if (length(old_by_per_level)) {
                new_by <- new_by_per_level[new_levels == really_new_levels[j]]
                rnames <- as.vector(get_rnames(sub_ranef, bylevels = new_by))
              } else {
                rnames <- get_rnames(sub_ranef)
              }
              sd_pars <- paste0("sd_", g, "__", rnames)
              sd_samples <- get_samples(samples, sd_pars, exact = TRUE)
              cor_type <- paste0("cor_", g)
              cor_pars <- get_cornames(rnames, cor_type, brackets = FALSE)
              cor_samples <- matrix(
                0, nrow = nrow(sd_samples), ncol = length(cor_pars)
              )
              for (k in seq_along(cor_pars)) {
                if (cor_pars[k] %in% colnames(samples)) {
                  cor_samples[, k] <- get_samples(
                    samples, cor_pars[k], exact = TRUE
                  )
                }
              }
              cov_matrix <- get_cov_matrix(sd_samples, cor_samples)
              # sample new levels from the normal distribution
              # implied by the covariance matrix
              indices <- ((j - 1) * nranef + 1):(j * nranef)
              new_rsamples[[i]][, indices] <- t(apply(
                cov_matrix, 1, rmulti_normal, 
                n = 1, mu = rep(0, length(sd_pars))
              ))
            }
          }
          max_level <- max_level + length(new_indices)
        } else if (sample_new_levels == "uncertainty") {
          new_rsamples[[i]] <- matrix(nrow = nrow(rsamples), ncol = nranef)
          for (k in seq_len(nranef)) {
            # sample values for the new level
            indices <- ((k - 1) * nlevels + 1):(k * nlevels)
            new_rsamples[[i]][, k] <- apply(
              rsamples[, indices, drop = FALSE], 1, sample, size = 1
            )
          }
          max_level <- max_level + 1
          gf[[i]][gf[[i]] > nlevels] <- max_level
        }
      } else { 
        new_rsamples[[i]] <- matrix(nrow = nrow(rsamples), ncol = 0)
      }
    }
    new_rsamples <- do.call(cbind, new_rsamples)
    # we need row major instead of column major order
    sort_levels <- ulapply(seq_len(nlevels),
      function(l) seq(l, ncol(rsamples), nlevels)
    )
    rsamples <- rsamples[, sort_levels, drop = FALSE]
    # new samples are already in row major order
    rsamples <- cbind(rsamples, new_rsamples)
    levels <- unique(unlist(gf))
    rsamples <- subset_levels(rsamples, levels, nranef)
    # special group-level terms (mo, me, mi)
    sub_ranef_sp <- subset2(sub_ranef, type = "sp")
    if (nrow(sub_ranef_sp)) {
      Z <- matrix(1, length(gf[[1]])) 
      draws[["Zsp"]][[g]] <- prepare_Z(Z, gf, max_level, weights)
      for (co in sub_ranef_sp$coef) {
        take <- which(sub_ranef$coef == co & sub_ranef$type == "sp")
        take <- take + nranef * (seq_along(levels) - 1)
        draws[["rsp"]][[co]][[g]] <- rsamples[, take, drop = FALSE]
      }
    }
    # category specific group-level terms
    sub_ranef_cs <- subset2(sub_ranef, type = "cs")
    if (nrow(sub_ranef_cs)) {
      # all categories share the same Z matrix
      take <- grepl("\\[1\\]$", sub_ranef_cs$coef)
      Znames <- paste0(
        "Z_", sub_ranef_cs$id[take], usc(p), "_", sub_ranef_cs$cn[take]
      )
      Z <- do.call(cbind, sdata[Znames])
      draws[["Zcs"]][[g]] <- prepare_Z(Z, gf, max_level, weights)
      for (i in seq_len(sdata$ncat - 1)) {
        index <- paste0("\\[", i, "\\]$")
        take <- which(grepl(index, sub_ranef$coef) & sub_ranef$type == "cs")
        take <- as.vector(outer(take, nranef * (seq_along(levels) - 1), "+"))
        draws[["rcs"]][[g]][[i]] <- rsamples[, take, drop = FALSE]
      }
    }
    # basic group-level effects
    sub_ranef_basic <- subset2(sub_ranef, type = c("", "mmc"))
    if (nrow(sub_ranef_basic)) {
      Znames <- paste0(
        "Z_", sub_ranef_basic$id, usc(p), "_", sub_ranef_basic$cn
      )
      if (sub_ranef_basic$gtype[1] == "mm") {
        ng <- length(sub_ranef_basic$gcall[[1]]$groups)
        Z <- vector("list", ng)
        for (k in seq_len(ng)) {
          Z[[k]] <- do.call(cbind, sdata[paste0(Znames, "_", k)])
        }
      } else {
        Z <- do.call(cbind, sdata[Znames])
      }
      draws[["Z"]][[g]] <- prepare_Z(Z, gf, max_level, weights)
      take <- which(sub_ranef$type %in% c("", "mmc"))
      take <- as.vector(outer(take, nranef * (seq_along(levels) - 1), "+"))
      rsamples <- rsamples[, take, drop = FALSE]
      draws[["r"]][[g]] <- rsamples
    }
  }
  draws
}

extract_draws_offset <- function(bterms, samples, sdata, ...) {
  p <- usc(combine_prefix(bterms))
  sdata[[paste0("offset", p)]]
}

extract_draws_autocor <- function(bterms, samples, sdata, new = FALSE, ...) {
  # extract draws of autocorrelation parameters
  draws <- list()
  autocor <- bterms$autocor
  p <- usc(combine_prefix(bterms))
  draws$N_tg <- sdata[[paste0("N_tg", p)]]
  if (get_ar(autocor) || get_ma(autocor)) {
    draws$Y <- sdata[[paste0("Y", p)]]
    draws$J_lag <- sdata[[paste0("J_lag", p)]]
    if (get_ar(autocor)) {
      draws$ar <- get_samples(samples, paste0("^ar", p, "\\["))
    }
    if (get_ma(autocor)) {
      draws$ma <- get_samples(samples, paste0("^ma", p, "\\["))
    }
    if (use_cov(autocor)) {
      draws$begin_tg <- sdata[[paste0("begin_tg", p)]]
      draws$nobs_tg <- sdata[[paste0("nobs_tg", p)]]
    }
  }
  if (get_arr(autocor)) {
    draws$arr <- get_samples(samples, paste0("^arr", p, "\\["))
    draws$Yarr <- sdata[[paste0("Yarr", p)]]
  }
  if (is.cor_sar(autocor)) {
    draws$lagsar <- get_samples(samples, paste0("^lagsar", p, "$"))
    draws$errorsar <- get_samples(samples, paste0("^errorsar", p, "$"))
    draws$W <- sdata[[paste0("W", p)]]
  }
  if (is.cor_car(autocor)) {
    if (new) {
      group <- parse_time(autocor)$group
      if (!isTRUE(nzchar(group))) {
        stop2("Without a grouping factor, CAR models cannot handle newdata.")
      }
    }
    gcar <- sdata[[paste0("Jloc", p)]]
    Zcar <- matrix(rep(1, length(gcar)))
    draws$Zcar <- prepare_Z(Zcar, list(gcar))
    rcar <- get_samples(samples, paste0("^rcar", p, "\\["))
    rcar <- rcar[, unique(gcar), drop = FALSE]
    draws$rcar <- rcar
  }
  if (is.cor_bsts(autocor)) {
    if (new) {
      warning2(
        "Local level terms are currently ignored ", 
        "when 'newdata' is specified."
      )
    } else {
      draws$loclev <- get_samples(samples, paste0("^loclev", p, "\\["))
    }
  }
  draws
}

extract_draws_data <- function(bterms, sdata, stanvars = NULL, ...) {
  # extract data mainly related to the response variable
  # Args
  #   stanvars: *names* of variables stored in slot 'stanvars'
  vars <- c(
    "Y", "trials", "ncat", "se", "weights", 
    "dec", "cens", "rcens", "lb", "ub"
  )
  resp <- usc(combine_prefix(bterms))
  draws <- rmNULL(sdata[paste0(vars, resp)], recursive = FALSE)
  if (length(stanvars)) {
    stopifnot(is.character(stanvars))
    draws[stanvars] <- sdata[stanvars]
  }
  draws
}

pseudo_draws_for_mixture <- function(draws, comp, sample_ids = NULL) {
  # create pseudo brmsdraws objects for components of mixture models
  # Args:
  #   comp: the mixture component number
  #   sample_ids: see predict_mixture
  stopifnot(is.brmsdraws(draws), is.mixfamily(draws$f))
  if (!is.null(sample_ids)) {
    nsamples <- length(sample_ids)
  } else {
    nsamples <- draws$nsamples
  }
  out <- list(
    f = draws$f$mix[[comp]], nsamples = nsamples,
    nobs = draws$nobs, data = draws$data
  )
  out$f$fun <- out$f$family
  for (dp in valid_dpars(out$f)) {
    out$dpars[[dp]] <- draws$dpars[[paste0(dp, comp)]]
    if (length(sample_ids) && length(out$dpars[[dp]]) > 1L) {
      out$dpars[[dp]] <- p(out$dpars[[dp]], sample_ids, row = TRUE)
    }
  }
  structure(out, class = "brmsdraws")
}

subset_levels <- function(x, levels, nranef) {
  # take relevant cols of a matrix of group-level terms
  # if only a subset of levels is provided (for newdata)
  # Args:
  #   x: a matrix typically samples of r or Z design matrices
  #   levels: grouping factor levels to keep
  #   nranef: number of group-level effects
  take_levels <- ulapply(levels, 
    function(l) ((l - 1) * nranef + 1):(l * nranef)
  )
  x[, take_levels, drop = FALSE]
}

prepare_Z <- function(Z, gf, max_level = NULL, weights = NULL) {
  # prepare group-level design matrices for use in linear_predictor
  # Args:
  #   Z: (list of) matrices to be prepared
  #   gf: (list of) vectors containing grouping factor values
  #   weights: optional (list of) weights of the same length as gf
  #   max_level: maximal level of gf
  if (!is.list(Z)) {
    Z <- list(Z)
  }
  if (!is.list(gf)) {
    gf <- list(gf)
  }
  if (is.null(weights)) {
    weights <- rep(1, length(gf[[1]]))
  }
  if (!is.list(weights)) {
    weights <- list(weights)
  }
  if (is.null(max_level)) {
    max_level <- max(unlist(gf))
  }
  levels <- unique(unlist(gf))
  nranef <- ncol(Z[[1]])
  Z <- mapply(
    expand_matrix, A = Z, x = gf, weights = weights,
    MoreArgs = nlist(max_level)
  )
  Z <- Reduce("+", Z)
  subset_levels(Z, levels, nranef)
}

expand_matrix <- function(A, x, max_level = max(x), weights = 1) {
  # expand a matrix into a sparse matrix of higher dimension
  # Args:
  #   A: matrix to be expanded
  #   x: levels to expand the matrix
  #   max_level: maximal number of levels that x can take on
  #   weights: weights to apply to rows of A before expanding
  # Returns:
  #   A sparse matrix of dimension nrow(A) x (ncol(A) * max_level)
  stopifnot(is.matrix(A))
  stopifnot(length(x) == nrow(A))
  stopifnot(all(is_wholenumber(x) & x > 0))
  stopifnot(length(weights) %in% c(1, nrow(A), prod(dim(A))))
  A <- A * as.vector(weights)
  K <- ncol(A)
  i <- rep(seq_along(x), each = K)
  make_j <- function(n, K, x) K * (x[n] - 1) + 1:K
  j <- ulapply(seq_along(x), make_j, K = K, x = x)
  Matrix::sparseMatrix(
    i = i, j = j, x = as.vector(t(A)),
    dims = c(nrow(A), ncol(A) * max_level)
  )
}

get_samples <- function(x, pars, ...) {
  pars <- extract_pars(pars, all_pars = colnames(x), ...)
  x[, pars, drop = FALSE]
}

is.brmsdraws <- function(x) {
  inherits(x, "brmsdraws")
}

is.mvbrmsdraws <- function(x) {
  inherits(x, "mvbrmsdraws")
}

is.bdrawsl <- function(x) {
  inherits(x, "bdrawsl")
}

is.bdrawsnl <- function(x) {
  inherits(x, "bdrawsnl")
}


